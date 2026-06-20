#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

load_env "$SCRIPT_DIR/../.env"
validate_env "AWS_REGION" "RESOURCE_SUFFIX"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

SNS_TOPIC_NAME="order-notifications-$RESOURCE_SUFFIX"
if ! aws sns get-topic-attributes --topic-arn "arn:aws:sns:$AWS_REGION:$ACCOUNT_ID:$SNS_TOPIC_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "ERRO: SNS topic $SNS_TOPIC_NAME not found. Deploy deploy-api-flow.sh first."
    exit 1
fi
ROLE_NAME="order-persister-role-$RESOURCE_SUFFIX"
LAMBDA_NAME="order-persister-$RESOURCE_SUFFIX"
QUEUE_NAME="order-persister-queue-$RESOURCE_SUFFIX"
DLQ_NAME="order-persister-dlq-$RESOURCE_SUFFIX"
EVENT_BUS_NAME="orders-event-bus-$RESOURCE_SUFFIX"
TABLE_NAME="order-production-data-$RESOURCE_SUFFIX"
EVENTBRIDGE_RULE_NAME="orders-persist-validated-$RESOURCE_SUFFIX"

# === DynamoDB Table ===
if ! aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws dynamodb create-table --table-name "$TABLE_NAME" \
        --attribute-definitions AttributeName=orderId,AttributeType=S \
        --key-schema AttributeName=orderId,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST --region "$AWS_REGION"
    aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$AWS_REGION"
fi
PRODUCTION_TABLE_ARN=$(aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$AWS_REGION" --query Table.TableArn --output text)
validate_not_empty "PRODUCTION_TABLE_ARN" "$PRODUCTION_TABLE_ARN" "DynamoDB Table ARN"

# === IAM Role ===
ensure_iam_lambda_role "$ROLE_NAME"

# === SQS Queues ===
DLQ_ARN=$(ensure_sqs_dlq "$DLQ_NAME" "$AWS_REGION" "false")
validate_not_empty "DLQ_ARN" "$DLQ_ARN" "Persister DLQ ARN"

ensure_sqs_queue "$QUEUE_NAME" "$DLQ_ARN" "$AWS_REGION" "false" ""

# Inline policy (must be after QUEUE_ARN is resolved)
SNS_TOPIC_ARN=$(aws sns get-topic-attributes --topic-arn "arn:aws:sns:$AWS_REGION:$ACCOUNT_ID:order-notifications-$RESOURCE_SUFFIX" --query Attributes.TopicArn --output text --region "$AWS_REGION" 2>/dev/null || echo "")
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "OrderProductionDynamoDB" --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"dynamodb:PutItem\",\"Resource\":\"$PRODUCTION_TABLE_ARN\"},{\"Effect\":\"Allow\",\"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:GetQueueAttributes\"],\"Resource\":\"$QUEUE_ARN\"},{\"Effect\":\"Allow\",\"Action\":\"sns:Publish\",\"Resource\":\"$SNS_TOPIC_ARN\"}]}"

# === EventBridge Rule -> SQS ===
aws events put-rule --name "$EVENTBRIDGE_RULE_NAME" --event-bus-name "$EVENT_BUS_NAME" --event-pattern '{"source":["app.orders.validation"],"detail-type":["OrderValidated"]}' --region "$AWS_REGION"
put_eventbridge_target "$EVENTBRIDGE_RULE_NAME" "$EVENT_BUS_NAME" "$QUEUE_ARN" "order-persister" "$AWS_REGION" "false"
validate_eventbridge_target "$EVENTBRIDGE_RULE_NAME" "$EVENT_BUS_NAME" "$QUEUE_ARN" "$AWS_REGION" "false"

# SqS Queue Policy for EventBridge
RULE_ARN="arn:aws:events:$AWS_REGION:$ACCOUNT_ID:rule/$EVENT_BUS_NAME/$EVENTBRIDGE_RULE_NAME"
aws sqs set-queue-attributes --queue-url "$QUEUE_URL" --attributes "{\"Policy\":\"{\\\"Version\\\":\\\"2012-10-17\\\",\\\"Statement\\\":[{\\\"Effect\\\":\\\"Allow\\\",\\\"Principal\\\":{\\\"Service\\\":\\\"events.amazonaws.com\\\"},\\\"Action\\\":\\\"sqs:SendMessage\\\",\\\"Resource\\\":\\\"$QUEUE_ARN\\\",\\\"Condition\\\":{\\\"ArnLike\\\":{\\\"aws:SourceArn\\\":\\\"$RULE_ARN\\\"}}}]}\"}" --region "$AWS_REGION"
validate_sqs_policy "$QUEUE_URL" "$AWS_REGION" "$QUEUE_ARN" "events.amazonaws.com" "sqs:SendMessage" "$RULE_ARN"

# === Lambda Deployment ===
PKG_DIR=$(mktemp -d)
cp ../src/order_processor/index.py "$PKG_DIR/"
mkdir -p "$PKG_DIR/common"
cp ../src/common/*.py "$PKG_DIR/common/"
cd "$PKG_DIR"
zip -qr "$SCRIPT_DIR/lambda_deploy.zip" .
cd "$SCRIPT_DIR"
rm -rf "$PKG_DIR"

ensure_lambda_function "$LAMBDA_NAME" "$ROLE_NAME" "index.lambda_handler" "lambda_deploy.zip" "$AWS_REGION" "$ACCOUNT_ID" "DYNAMODB_TABLE=$TABLE_NAME,SNS_TOPIC_ARN=$SNS_TOPIC_ARN"
validate_lambda_config "$LAMBDA_NAME" "$AWS_REGION" "DYNAMODB_TABLE" "SNS_TOPIC_ARN"

ensure_event_source_mapping "$LAMBDA_NAME" "$QUEUE_ARN" "$AWS_REGION"

rm -f lambda_deploy.zip
