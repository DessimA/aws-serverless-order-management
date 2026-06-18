#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

load_env "$SCRIPT_DIR/../.env"
validate_env "AWS_REGION" "RESOURCE_SUFFIX"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
EVENT_BUS_NAME="orders-event-bus-$RESOURCE_SUFFIX"
TABLE_NAME="order-production-data-$RESOURCE_SUFFIX"
PRODUCTION_TABLE_ARN=$(aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$AWS_REGION" --query Table.TableArn --output text)

deploy_lifecycle_handler() {
    local OPERATION="$1"
    local QUEUE_NAME="${OPERATION}-order-queue-${RESOURCE_SUFFIX}.fifo"
    local DLQ_NAME="${OPERATION}-order-dlq-${RESOURCE_SUFFIX}.fifo"
    local LAMBDA_NAME="order-lifecycle-${OPERATION}-${RESOURCE_SUFFIX}"
    local ROLE_NAME="order-lifecycle-${OPERATION}-role-${RESOURCE_SUFFIX}"
    local RULE_NAME="orders-${OPERATION}-${RESOURCE_SUFFIX}"

    local DETAIL_TYPE
    case "$OPERATION" in
        cancel) DETAIL_TYPE="OrderCancelled" ;;
        update) DETAIL_TYPE="OrderUpdated" ;;
        *) echo "Unknown operation: $OPERATION" >&2; exit 1 ;;
    esac

    # ========== SQS Queues ==========
    if ! aws sqs get-queue-url --queue-name "$DLQ_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
        aws sqs create-queue --queue-name "$DLQ_NAME" --attributes "{\"FifoQueue\":\"true\"}" --region "$AWS_REGION"
    fi
    local DLQ_ARN
    DLQ_ARN=$(aws sqs get-queue-attributes --queue-url "$(aws sqs get-queue-url --queue-name "$DLQ_NAME" --region "$AWS_REGION" --query QueueUrl --output text)" --attribute-names QueueArn --query Attributes.QueueArn --output text --region "$AWS_REGION")

    if ! aws sqs get-queue-url --queue-name "$QUEUE_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
        aws sqs create-queue --queue-name "$QUEUE_NAME" --attributes "{\"FifoQueue\":\"true\",\"VisibilityTimeout\":\"90\",\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"$DLQ_ARN\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"}" --region "$AWS_REGION"
    fi
    local QUEUE_URL QUEUE_ARN
    QUEUE_URL=$(aws sqs get-queue-url --queue-name "$QUEUE_NAME" --region "$AWS_REGION" --query QueueUrl --output text)
    QUEUE_ARN=$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text --region "$AWS_REGION")
    aws sqs set-queue-attributes --queue-url "$QUEUE_URL" --attributes "{\"VisibilityTimeout\":\"90\"}" --region "$AWS_REGION"
    wait_for_sqs_queue "$QUEUE_NAME" "$AWS_REGION"

    # ========== IAM ==========
    if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
        aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
        aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
        aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "OrderLifecycleDynamoDB" --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"dynamodb:UpdateItem\",\"dynamodb:GetItem\"],\"Resource\":\"$PRODUCTION_TABLE_ARN\"},{\"Effect\":\"Allow\",\"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:GetQueueAttributes\"],\"Resource\":\"$QUEUE_ARN\"}]}"
    fi
    wait_for_iam_role "$ROLE_NAME"

    # ========== EventBridge Rule -> SQS ==========
    aws events put-rule --name "$RULE_NAME" --event-bus-name "$EVENT_BUS_NAME" --event-pattern "{\"source\":[\"app.orders.operations\"],\"detail-type\":[\"$DETAIL_TYPE\"]}" --region "$AWS_REGION"
    put_eventbridge_target "$RULE_NAME" "$EVENT_BUS_NAME" "$QUEUE_ARN" "order-lifecycle-${OPERATION}" "$AWS_REGION"

    aws sqs set-queue-attributes --queue-url "$QUEUE_URL" --attributes "{\"Policy\":\"{\\\"Version\\\":\\\"2012-10-17\\\",\\\"Statement\\\":[{\\\"Effect\\\":\\\"Allow\\\",\\\"Principal\\\":{\\\"Service\\\":\\\"events.amazonaws.com\\\"},\\\"Action\\\":\\\"sqs:SendMessage\\\",\\\"Resource\\\":\\\"$QUEUE_ARN\\\",\\\"Condition\\\":{\\\"ArnLike\\\":{\\\"aws:SourceArn\\\":\\\"arn:aws:events:$AWS_REGION:$ACCOUNT_ID:rule/$EVENT_BUS_NAME/$RULE_NAME\\\"}}}]}\"}" --region "$AWS_REGION"

    # ========== Lambda Deployment ==========
    local SRC_DIR="../src/lifecycle_ops"
    cd "$SRC_DIR"
    zip -q "../../scripts/lambda_deploy_${OPERATION}.zip" "${OPERATION}_order.py"
    cd "$SCRIPT_DIR"

    if ! aws lambda get-function --function-name "$LAMBDA_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
        echo "Criando funcao Lambda $LAMBDA_NAME..."
        for i in {1..3}; do
            aws lambda create-function --function-name "$LAMBDA_NAME" --runtime python3.12 --role "arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME" --handler "${OPERATION}_order.lambda_handler" --zip-file "fileb://lambda_deploy_${OPERATION}.zip" --timeout 60 --region "$AWS_REGION" && break || sleep 10
        done
        aws lambda wait function-active-v2 --function-name "$LAMBDA_NAME" --region "$AWS_REGION"
    else
        aws lambda update-function-code --function-name "$LAMBDA_NAME" --zip-file "fileb://lambda_deploy_${OPERATION}.zip" --region "$AWS_REGION"
        aws lambda wait function-updated-v2 --function-name "$LAMBDA_NAME" --region "$AWS_REGION"
    fi

    aws lambda update-function-configuration --function-name "$LAMBDA_NAME" --timeout 60 --environment "Variables={DYNAMODB_TABLE=$TABLE_NAME}" --region "$AWS_REGION"

    # ========== SQS -> Lambda Event Source Mapping ==========
    if ! aws lambda list-event-source-mappings --function-name "$LAMBDA_NAME" --event-source-arn "$QUEUE_ARN" --region "$AWS_REGION" --query "EventSourceMappings[0]" --output text >/dev/null 2>&1; then
        aws lambda create-event-source-mapping --function-name "$LAMBDA_NAME" --batch-size 5 --event-source-arn "$QUEUE_ARN" --region "$AWS_REGION"
    fi

    rm -f "lambda_deploy_${OPERATION}.zip"
}

deploy_lifecycle_handler "cancel"
deploy_lifecycle_handler "update"
