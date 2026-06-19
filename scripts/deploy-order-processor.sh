#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

load_env "$SCRIPT_DIR/../.env"
validate_env "AWS_REGION" "RESOURCE_SUFFIX"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_NAME="order-persister-role-$RESOURCE_SUFFIX"
LAMBDA_NAME="order-persister-$RESOURCE_SUFFIX"
QUEUE_NAME="order-persister-queue-$RESOURCE_SUFFIX.fifo"
DLQ_NAME="order-persister-dlq-$RESOURCE_SUFFIX.fifo"
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

# === IAM Role ===
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
    aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
fi
wait_for_iam_role "$ROLE_NAME"

# === SQS Queues ===
if ! aws sqs get-queue-url --queue-name "$DLQ_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws sqs create-queue --queue-name "$DLQ_NAME" --attributes "{\"FifoQueue\":\"true\"}" --region "$AWS_REGION"
fi
DLQ_ARN=$(aws sqs get-queue-attributes --queue-url "$(aws sqs get-queue-url --queue-name "$DLQ_NAME" --region "$AWS_REGION" --query QueueUrl --output text)" --attribute-names QueueArn --query Attributes.QueueArn --output text --region "$AWS_REGION")

if ! aws sqs get-queue-url --queue-name "$QUEUE_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws sqs create-queue --queue-name "$QUEUE_NAME" --attributes "{\"FifoQueue\":\"true\",\"VisibilityTimeout\":\"90\",\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"$DLQ_ARN\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"}" --region "$AWS_REGION"
fi
QUEUE_URL=$(aws sqs get-queue-url --queue-name "$QUEUE_NAME" --region "$AWS_REGION" --query QueueUrl --output text)
QUEUE_ARN=$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text --region "$AWS_REGION")
aws sqs set-queue-attributes --queue-url "$QUEUE_URL" --attributes "{\"VisibilityTimeout\":\"90\"}" --region "$AWS_REGION"
wait_for_sqs_queue "$QUEUE_NAME" "$AWS_REGION"

# Inline policy (must be after QUEUE_ARN is resolved)
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "OrderProductionDynamoDB" --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"dynamodb:PutItem\",\"dynamodb:UpdateItem\",\"dynamodb:GetItem\"],\"Resource\":\"$PRODUCTION_TABLE_ARN\"},{\"Effect\":\"Allow\",\"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:GetQueueAttributes\"],\"Resource\":\"$QUEUE_ARN\"}]}"

# === EventBridge Rule -> SQS ===
aws events put-rule --name "$EVENTBRIDGE_RULE_NAME" --event-bus-name "$EVENT_BUS_NAME" --event-pattern '{"source":["app.orders.validation"],"detail-type":["OrderValidated"]}' --region "$AWS_REGION"
put_eventbridge_target "$EVENTBRIDGE_RULE_NAME" "$EVENT_BUS_NAME" "$QUEUE_ARN" "order-persister" "$AWS_REGION"

# SqS Queue Policy for EventBridge
aws sqs set-queue-attributes --queue-url "$QUEUE_URL" --attributes "{\"Policy\":\"{\\\"Version\\\":\\\"2012-10-17\\\",\\\"Statement\\\":[{\\\"Effect\\\":\\\"Allow\\\",\\\"Principal\\\":{\\\"Service\\\":\\\"events.amazonaws.com\\\"},\\\"Action\\\":\\\"sqs:SendMessage\\\",\\\"Resource\\\":\\\"$QUEUE_ARN\\\",\\\"Condition\\\":{\\\"ArnLike\\\":{\\\"aws:SourceArn\\\":\\\"arn:aws:events:$AWS_REGION:$ACCOUNT_ID:rule/$EVENT_BUS_NAME/$EVENTBRIDGE_RULE_NAME\\\"}}}]}\"}" --region "$AWS_REGION"

# === Lambda Deployment ===
cd ../src/order_processor
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

aws lambda update-function-configuration --function-name "$LAMBDA_NAME" --timeout 60 --environment "Variables={DYNAMODB_TABLE=$TABLE_NAME}" --region "$AWS_REGION"

# === SQS -> Lambda Event Source Mapping ===
ESM_UUID=$(aws lambda list-event-source-mappings --function-name "$LAMBDA_NAME" --event-source-arn "$QUEUE_ARN" --region "$AWS_REGION" --query "EventSourceMappings[0].UUID" --output text)
if [ -z "$ESM_UUID" ] || [ "$ESM_UUID" == "None" ]; then
    aws lambda create-event-source-mapping --function-name "$LAMBDA_NAME" --batch-size 5 --event-source-arn "$QUEUE_ARN" --region "$AWS_REGION"
fi

rm -f lambda_deploy.zip
