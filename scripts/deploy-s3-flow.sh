#!/usr/bin/env bash
set -euo pipefail

if [ -f ../.env ]; then export $(grep -v '^#' ../.env | xargs); fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="$AWS_REGION"
SUFFIX="$RESOURCE_SUFFIX"

ROLE_NAME="order-batch-processor-role-$SUFFIX"
BUCKET_NAME="order-drop-zone-$SUFFIX"
TABLE_NAME="order-processing-history-$SUFFIX"
SNS_TOPIC_NAME="order-error-notifications-$SUFFIX"
SQS_S3_NAME="s3-event-bridge-queue-$SUFFIX"
BUS_NAME="pedidos-event-bus-$SUFFIX"
LAMBDA_NAME="order-s3-batch-processor-$SUFFIX"
FIFO_QUEUE_URL="https://sqs.$REGION.amazonaws.com/$ACCOUNT_ID/order-ingestion-queue-$SUFFIX.fifo"

# 1. IAM Role com pausa
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
    aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    echo "Aguardando propagacao do IAM Role..."
    sleep 15
fi

# 2. Infraestrutura (SNS, Dynamo, SQS, S3)
SNS_ARN=$(aws sns create-topic --name "$SNS_TOPIC_NAME" --region "$REGION" --query TopicArn --output text)
aws sns subscribe --topic-arn "$SNS_ARN" --protocol email --notification-endpoint "$NOTIFICATION_EMAIL" --region "$REGION" >/dev/null

if ! aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$REGION" >/dev/null 2>&1; then
    aws dynamodb create-table --table-name "$TABLE_NAME" --attribute-definitions AttributeName=file_name,AttributeType=S --key-schema AttributeName=file_name,KeyType=HASH --billing-mode PAY_PER_REQUEST --region "$REGION"
fi

if ! aws sqs get-queue-url --queue-name "$SQS_S3_NAME" --region "$REGION" >/dev/null 2>&1; then
    aws sqs create-queue --queue-name "$SQS_S3_NAME" --attributes "{\"VisibilityTimeout\":\"120\"}" --region "$REGION"
fi
SQS_S3_URL=$(aws sqs get-queue-url --queue-name "$SQS_S3_NAME" --region "$REGION" --query QueueUrl --output text)
SQS_S3_ARN=$(aws sqs get-queue-attributes --queue-url "$SQS_S3_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text --region "$REGION")

if ! aws s3api head-bucket --bucket "$BUCKET_NAME" >/dev/null 2>&1; then
    aws s3 mb "s3://$BUCKET_NAME" --region "$REGION"
fi

aws sqs set-queue-attributes --queue-url "$SQS_S3_URL" --region "$REGION" --attributes "{\"Policy\":\"{\\\"Version\\\":\\\"2012-10-17\\\",\\\"Statement\\\":[{\\\"Effect\\\":\\\"Allow\\\",\\\"Principal\\\":{\\\"Service\\\":\\\"s3.amazonaws.com\\\"},\\\"Action\\\":\\\"SQS:SendMessage\\\",\\\"Resource\\\":\\\"$SQS_S3_ARN\\\",\\\"Condition\\\":{\\\"ArnLike\\\":{\\\"aws:SourceArn\\\":\\\"arn:aws:s3:::$BUCKET_NAME\\\"}}}]}\"}"
aws s3api put-bucket-notification-configuration --bucket "$BUCKET_NAME" --region "$REGION" --notification-configuration "{\"QueueConfigurations\":[{\"QueueArn\":\"$SQS_S3_ARN\",\"Events\":[\"s3:ObjectCreated:*\"],\"Filter\":{\"Key\":{\"FilterRules\":[{\"Name\":\"suffix\",\"Value\":\".json\"}]}}}]}"

# 3. Permissoes
BUS_ARN="arn:aws:events:$REGION:$ACCOUNT_ID:event-bus/$BUS_NAME"
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "BatchProcessorPolicy" --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::$BUCKET_NAME/*\"},{\"Effect\":\"Allow\",\"Action\":\"dynamodb:PutItem\",\"Resource\":\"arn:aws:dynamodb:$REGION:$ACCOUNT_ID:table/$TABLE_NAME\"},{\"Effect\":\"Allow\",\"Action\":\"sns:Publish\",\"Resource\":\"$SNS_ARN\"},{\"Effect\":\"Allow\",\"Action\":\"events:PutEvents\",\"Resource\":\"$BUS_ARN\"},{\"Effect\":\"Allow\",\"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:GetQueueAttributes\"],\"Resource\":\"$SQS_S3_ARN\"}]}"

# 4. Lambda Deployment
cd ../src/batch_processor
zip -q ../../scripts/batch_lambda.zip index.py
cd ../../scripts

if ! aws lambda get-function --function-name "$LAMBDA_NAME" --region "$REGION" >/dev/null 2>&1; then
    for i in {1..3}; do
        aws lambda create-function --function-name "$LAMBDA_NAME" --runtime python3.12 --role "arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME" --handler index.lambda_handler --zip-file fileb://batch_lambda.zip --region "$REGION" --timeout 60 && break || sleep 10
    done
    aws lambda wait function-active-v2 --function-name "$LAMBDA_NAME" --region "$REGION"
else
    aws lambda update-function-code --function-name "$LAMBDA_NAME" --zip-file fileb://batch_lambda.zip --region "$REGION"
    aws lambda wait function-updated-v2 --function-name "$LAMBDA_NAME" --region "$REGION"
fi

aws lambda update-function-configuration --function-name "$LAMBDA_NAME" --region "$REGION" --environment "Variables={DYNAMODB_TABLE=$TABLE_NAME,SNS_TOPIC_ARN=$SNS_ARN,EVENT_BUS_NAME=$BUS_NAME}"
aws lambda wait function-updated-v2 --function-name "$LAMBDA_NAME" --region "$REGION"

MAPPING_UUID=$(aws lambda list-event-source-mappings --function-name "$LAMBDA_NAME" --region "$REGION" --query "EventSourceMappings[?EventSourceArn=='$SQS_S3_ARN'].UUID" --output text)
if [ -z "$MAPPING_UUID" ] || [ "$MAPPING_UUID" == "None" ]; then
    aws lambda create-event-source-mapping --function-name "$LAMBDA_NAME" --event-source-arn "$SQS_S3_ARN" --region "$REGION"
fi
rm batch_lambda.zip