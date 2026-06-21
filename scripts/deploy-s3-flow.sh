#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
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
validate_not_empty "BUCKET_NAME" "$BUCKET_NAME" "S3 Files Bucket"

# === SQS Queues (Standard) ===
DLQ_ARN=$(ensure_sqs_dlq "$DLQ_NAME" "$AWS_REGION" "false")
validate_not_empty "DLQ_ARN" "$DLQ_ARN" "S3 Batch DLQ ARN"

ensure_sqs_queue "$S3_EVENT_QUEUE_NAME" "$DLQ_ARN" "$AWS_REGION" "false" ""
S3_EVENT_QUEUE_URL="$QUEUE_URL"
S3_EVENT_QUEUE_ARN="$QUEUE_ARN"

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
ensure_iam_lambda_role "$ROLE_NAME"
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "FileValidatorAccess" --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::$BUCKET_NAME/*\"},{\"Effect\":\"Allow\",\"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:GetQueueAttributes\"],\"Resource\":\"$S3_EVENT_QUEUE_ARN\"},{\"Effect\":\"Allow\",\"Action\":[\"dynamodb:PutItem\"],\"Resource\":\"arn:aws:dynamodb:$AWS_REGION:$ACCOUNT_ID:table/$AUDIT_TABLE_NAME\"},{\"Effect\":\"Allow\",\"Action\":\"sns:Publish\",\"Resource\":\"arn:aws:sns:$AWS_REGION:$ACCOUNT_ID:$SNS_TOPIC_NAME\"}]}"

# === S3 → SQS Notification ===
S3_BUCKET_ARN="arn:aws:s3:::$BUCKET_NAME"
aws sqs set-queue-attributes --queue-url "$S3_EVENT_QUEUE_URL" --attributes "{\"Policy\":\"{\\\"Version\\\":\\\"2012-10-17\\\",\\\"Statement\\\":[{\\\"Effect\\\":\\\"Allow\\\",\\\"Principal\\\":{\\\"Service\\\":\\\"s3.amazonaws.com\\\"},\\\"Action\\\":\\\"sqs:SendMessage\\\",\\\"Resource\\\":\\\"$S3_EVENT_QUEUE_ARN\\\",\\\"Condition\\\":{\\\"ArnLike\\\":{\\\"aws:SourceArn\\\":\\\"$S3_BUCKET_ARN\\\"}}}]}\"}" --region "$AWS_REGION"
validate_sqs_policy "$S3_EVENT_QUEUE_URL" "$AWS_REGION" "$S3_EVENT_QUEUE_ARN" "s3.amazonaws.com" "sqs:SendMessage" "$S3_BUCKET_ARN"
sleep 5
S3_NOTIFICATION_CONFIG='{"QueueConfigurations":[{"Id":"'$S3_EVENT_QUEUE_NAME'","QueueArn":"'$S3_EVENT_QUEUE_ARN'","Events":["s3:ObjectCreated:*"]}]}'
aws s3api put-bucket-notification-configuration --bucket "$BUCKET_NAME" --notification-configuration "$S3_NOTIFICATION_CONFIG" --region "$AWS_REGION"

# === Lambda Deployment ===
PKG_DIR=$(mktemp -d)
cp ../src/batch_processor/index.py "$PKG_DIR/"
mkdir -p "$PKG_DIR/common"
cp ../src/common/*.py "$PKG_DIR/common/"
cd "$PKG_DIR"
zip -qr "$SCRIPT_DIR/lambda_deploy.zip" .
cd "$SCRIPT_DIR"
rm -rf "$PKG_DIR"

SNS_TOPIC_ARN=$(aws sns get-topic-attributes --topic-arn "arn:aws:sns:$AWS_REGION:$ACCOUNT_ID:$SNS_TOPIC_NAME" --query Attributes.TopicArn --output text --region "$AWS_REGION")
validate_not_empty "SNS_TOPIC_ARN" "$SNS_TOPIC_ARN" "SNS Topic ARN"
sns_subscribe_email "$SNS_TOPIC_ARN" "$NOTIFICATION_EMAIL" "$AWS_REGION"

ensure_lambda_function "$LAMBDA_NAME" "$ROLE_NAME" "index.lambda_handler" "lambda_deploy.zip" "$AWS_REGION" "$ACCOUNT_ID" "5" "DYNAMODB_TABLE=$AUDIT_TABLE_NAME,SNS_TOPIC_ARN=$SNS_TOPIC_ARN"
validate_lambda_config "$LAMBDA_NAME" "$AWS_REGION" "DYNAMODB_TABLE" "SNS_TOPIC_ARN"

ensure_event_source_mapping "$LAMBDA_NAME" "$S3_EVENT_QUEUE_ARN" "$AWS_REGION"

# === CloudWatch Alarm for DLQ ===
ensure_dlq_alarm "dlq-alarm-s3-batch-$RESOURCE_SUFFIX" "$DLQ_NAME" "$SNS_TOPIC_ARN" "$AWS_REGION"

# === TTL on Audit Table ===
TTL_STATUS=$(aws dynamodb describe-time-to-live --table-name "$AUDIT_TABLE_NAME" --region "$AWS_REGION" --query "TimeToLiveDescription.TimeToLiveStatus" --output text 2>/dev/null || echo "DISABLED")
if [ "$TTL_STATUS" != "ENABLED" ]; then
    echo "Habilitando TTL na tabela $AUDIT_TABLE_NAME (atributo: expiresAt)..."
    aws dynamodb update-time-to-live --table-name "$AUDIT_TABLE_NAME" --time-to-live-specification "Enabled=true,AttributeName=expiresAt" --region "$AWS_REGION"
fi

rm -f lambda_deploy.zip
