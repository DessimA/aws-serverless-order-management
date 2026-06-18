#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

load_env "$SCRIPT_DIR/../.env"
validate_env "AWS_REGION" "RESOURCE_SUFFIX" "NOTIFICATION_EMAIL"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_NAME="order-file-validator-role-$RESOURCE_SUFFIX"
LAMBDA_NAME="order-file-validator-$RESOURCE_SUFFIX"
S3_EVENT_QUEUE_NAME="order-s3-batch-queue-$RESOURCE_SUFFIX"
DLQ_NAME="order-s3-batch-dlq-$RESOURCE_SUFFIX"
SNS_TOPIC_NAME="order-notifications-$RESOURCE_SUFFIX"
AUDIT_TABLE_NAME="order-batch-audit-$RESOURCE_SUFFIX"
BUCKET_NAME="order-files-bucket-$RESOURCE_SUFFIX"

# === S3 Bucket ===
if ! aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" 2>/dev/null; then
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" \
        --create-bucket-configuration LocationConstraint="$AWS_REGION"
    sleep 2
    aws s3api put-bucket-notification-configuration --bucket "$BUCKET_NAME" \
        --notification-configuration '{"QueueConfigurations":[]}' --region "$AWS_REGION"
fi

# === SQS Queues (Standard) ===
if ! aws sqs get-queue-url --queue-name "$DLQ_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws sqs create-queue --queue-name "$DLQ_NAME" --region "$AWS_REGION"
fi
DLQ_ARN=$(aws sqs get-queue-attributes --queue-url "$(aws sqs get-queue-url --queue-name "$DLQ_NAME" --region "$AWS_REGION" --query QueueUrl --output text)" --attribute-names QueueArn --query Attributes.QueueArn --output text --region "$AWS_REGION")

if ! aws sqs get-queue-url --queue-name "$S3_EVENT_QUEUE_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws sqs create-queue --queue-name "$S3_EVENT_QUEUE_NAME" --attributes "{\"VisibilityTimeout\":\"90\",\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"$DLQ_ARN\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"}" --region "$AWS_REGION"
fi
S3_EVENT_QUEUE_URL=$(aws sqs get-queue-url --queue-name "$S3_EVENT_QUEUE_NAME" --region "$AWS_REGION" --query QueueUrl --output text)
S3_EVENT_QUEUE_ARN=$(aws sqs get-queue-attributes --queue-url "$S3_EVENT_QUEUE_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text --region "$AWS_REGION")
aws sqs set-queue-attributes --queue-url "$S3_EVENT_QUEUE_URL" --attributes "{\"VisibilityTimeout\":\"90\"}" --region "$AWS_REGION"
wait_for_sqs_queue "$S3_EVENT_QUEUE_NAME" "$AWS_REGION"

# === DynamoDB Audit Table ===
if ! aws dynamodb describe-table --table-name "$AUDIT_TABLE_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws dynamodb create-table --table-name "$AUDIT_TABLE_NAME" \
        --attribute-definitions AttributeName=file_name,AttributeType=S AttributeName=timestamp,AttributeType=S \
        --key-schema AttributeName=file_name,KeyType=HASH AttributeName=timestamp,KeyType=RANGE \
        --billing-mode PAY_PER_REQUEST --region "$AWS_REGION"
    aws dynamodb wait table-exists --table-name "$AUDIT_TABLE_NAME" --region "$AWS_REGION"
fi

# === SNS Topic (shared — created in deploy-api-flow.sh if not exists) ===
if ! aws sns get-topic-attributes --topic-arn "arn:aws:sns:$AWS_REGION:$ACCOUNT_ID:$SNS_TOPIC_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws sns create-topic --name "$SNS_TOPIC_NAME" --region "$AWS_REGION"
fi

# === IAM Role ===
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
    aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
fi
wait_for_iam_role "$ROLE_NAME"
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "FileValidatorAccess" --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::$BUCKET_NAME/*\"},{\"Effect\":\"Allow\",\"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:GetQueueAttributes\"],\"Resource\":\"$S3_EVENT_QUEUE_ARN\"},{\"Effect\":\"Allow\",\"Action\":[\"dynamodb:PutItem\"],\"Resource\":\"arn:aws:dynamodb:$AWS_REGION:$ACCOUNT_ID:table/$AUDIT_TABLE_NAME\"},{\"Effect\":\"Allow\",\"Action\":\"sns:Publish\",\"Resource\":\"arn:aws:sns:$AWS_REGION:$ACCOUNT_ID:$SNS_TOPIC_NAME\"}]}"

# === S3 → SQS Notification ===
aws sqs set-queue-attributes --queue-url "$S3_EVENT_QUEUE_URL" --attributes "{\"Policy\":\"{\\\"Version\\\":\\\"2012-10-17\\\",\\\"Statement\\\":[{\\\"Effect\\\":\\\"Allow\\\",\\\"Principal\\\":{\\\"Service\\\":\\\"s3.amazonaws.com\\\"},\\\"Action\\\":\\\"sqs:SendMessage\\\",\\\"Resource\\\":\\\"$S3_EVENT_QUEUE_ARN\\\",\\\"Condition\\\":{\\\"ArnLike\\\":{\\\"aws:SourceArn\\\":\\\"arn:aws:s3:::$BUCKET_NAME\\\"}}}]}\"}" --region "$AWS_REGION"
sleep 5
S3_NOTIFICATION_CONFIG='{"QueueConfigurations":[{"Id":"'$S3_EVENT_QUEUE_NAME'","QueueArn":"'$S3_EVENT_QUEUE_ARN'","Events":["s3:ObjectCreated:*"]}]}'
aws s3api put-bucket-notification-configuration --bucket "$BUCKET_NAME" --notification-configuration "$S3_NOTIFICATION_CONFIG" --region "$AWS_REGION"

# === Lambda Deployment ===
cd ../src/batch_processor
zip -q ../../scripts/lambda_deploy.zip index.py
cd ../../scripts

if ! aws lambda get-function --function-name "$LAMBDA_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "Criando funcao Lambda $LAMBDA_NAME..."
    for i in {1..3}; do
        aws lambda create-function --function-name "$LAMBDA_NAME" --runtime python3.12 --role "arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME" --handler index.lambda_handler --zip-file fileb://lambda_deploy.zip --timeout 60 --region "$AWS_REGION" && break || sleep 10
    done
    aws lambda wait function-active-v2 --function-name "$LAMBDA_NAME" --region "$AWS_REGION"
else
    aws lambda update-function-code --function-name "$LAMBDA_NAME" --zip-file fileb://lambda_deploy.zip --region "$AWS_REGION"
    aws lambda wait function-updated-v2 --function-name "$LAMBDA_NAME" --region "$AWS_REGION"
fi

SNS_TOPIC_ARN=$(aws sns get-topic-attributes --topic-arn "arn:aws:sns:$AWS_REGION:$ACCOUNT_ID:$SNS_TOPIC_NAME" --query Attributes.TopicArn --output text --region "$AWS_REGION")
aws sns subscribe --topic-arn "$SNS_TOPIC_ARN" --protocol email --notification-endpoint "$NOTIFICATION_EMAIL" --region "$AWS_REGION" 2>/dev/null || true
aws lambda update-function-configuration --function-name "$LAMBDA_NAME" --timeout 60 --environment "Variables={DYNAMODB_TABLE=$AUDIT_TABLE_NAME,SNS_TOPIC_ARN=$SNS_TOPIC_ARN}" --region "$AWS_REGION"

# === SQS → Lambda event source mapping ===
EVENT_SOURCE_MAPPING_UUID=$(aws lambda list-event-source-mappings --function-name "$LAMBDA_NAME" --region "$AWS_REGION" --query "EventSourceMappings[0].UUID" --output text)
if [ "$EVENT_SOURCE_MAPPING_UUID" == "None" ] || [ -z "$EVENT_SOURCE_MAPPING_UUID" ]; then
    aws lambda create-event-source-mapping --function-name "$LAMBDA_NAME" --batch-size 5 --event-source-arn "$S3_EVENT_QUEUE_ARN" --region "$AWS_REGION"
fi

rm -f lambda_deploy.zip
