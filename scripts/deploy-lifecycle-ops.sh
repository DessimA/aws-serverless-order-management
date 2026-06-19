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
validate_not_empty "PRODUCTION_TABLE_ARN" "$PRODUCTION_TABLE_ARN" "DynamoDB Production Table ARN"

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
    local DLQ_ARN
    DLQ_ARN=$(ensure_sqs_dlq "$DLQ_NAME" "$AWS_REGION" "true")
    validate_not_empty "DLQ_ARN" "$DLQ_ARN" "Lifecycle $OPERATION DLQ ARN"

    ensure_sqs_queue "$QUEUE_NAME" "$DLQ_ARN" "$AWS_REGION" "true" "true"

    # ========== IAM ==========
    ensure_iam_lambda_role "$ROLE_NAME"
    local SNS_TOPIC_ARN
    SNS_TOPIC_ARN=$(aws sns get-topic-attributes --topic-arn "arn:aws:sns:$AWS_REGION:$ACCOUNT_ID:order-notifications-$RESOURCE_SUFFIX" --query Attributes.TopicArn --output text --region "$AWS_REGION" 2>/dev/null || echo "")
    aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "OrderLifecycleDynamoDB" --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"dynamodb:UpdateItem\",\"dynamodb:GetItem\"],\"Resource\":\"$PRODUCTION_TABLE_ARN\"},{\"Effect\":\"Allow\",\"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:GetQueueAttributes\"],\"Resource\":\"$QUEUE_ARN\"},{\"Effect\":\"Allow\",\"Action\":\"sns:Publish\",\"Resource\":\"$SNS_TOPIC_ARN\"}]}"

    # ========== EventBridge Rule -> SQS ==========
    aws events put-rule --name "$RULE_NAME" --event-bus-name "$EVENT_BUS_NAME" --event-pattern "{\"source\":[\"app.orders.operations\"],\"detail-type\":[\"$DETAIL_TYPE\"]}" --region "$AWS_REGION"
    put_eventbridge_target "$RULE_NAME" "$EVENT_BUS_NAME" "$QUEUE_ARN" "order-lifecycle-${OPERATION}" "$AWS_REGION"
    validate_eventbridge_target "$RULE_NAME" "$EVENT_BUS_NAME" "$QUEUE_ARN" "$AWS_REGION"

    local LIFECYCLE_RULE_ARN="arn:aws:events:$AWS_REGION:$ACCOUNT_ID:rule/$EVENT_BUS_NAME/$RULE_NAME"
    aws sqs set-queue-attributes --queue-url "$QUEUE_URL" --attributes "{\"Policy\":\"{\\\"Version\\\":\\\"2012-10-17\\\",\\\"Statement\\\":[{\\\"Effect\\\":\\\"Allow\\\",\\\"Principal\\\":{\\\"Service\\\":\\\"events.amazonaws.com\\\"},\\\"Action\\\":\\\"sqs:SendMessage\\\",\\\"Resource\\\":\\\"$QUEUE_ARN\\\",\\\"Condition\\\":{\\\"ArnLike\\\":{\\\"aws:SourceArn\\\":\\\"$LIFECYCLE_RULE_ARN\\\"}}}]}\"}" --region "$AWS_REGION"
    validate_sqs_policy "$QUEUE_URL" "$AWS_REGION" "$QUEUE_ARN" "events.amazonaws.com" "sqs:SendMessage" "$LIFECYCLE_RULE_ARN"

    # ========== Lambda Deployment ==========
    PKG_DIR=$(mktemp -d)
    cp "../src/lifecycle_ops/index.py" "$PKG_DIR/"
    mkdir -p "$PKG_DIR/common"
    cp ../src/common/*.py "$PKG_DIR/common/"
    cd "$PKG_DIR"
    zip -qr "$SCRIPT_DIR/lambda_deploy_${OPERATION}.zip" .
    cd "$SCRIPT_DIR"
    rm -rf "$PKG_DIR"

    ensure_lambda_function "$LAMBDA_NAME" "$ROLE_NAME" "index.${OPERATION}_handler" "lambda_deploy_${OPERATION}.zip" "$AWS_REGION" "$ACCOUNT_ID" "DYNAMODB_TABLE=$TABLE_NAME,SNS_TOPIC_ARN=$SNS_TOPIC_ARN"
    validate_lambda_config "$LAMBDA_NAME" "$AWS_REGION" "DYNAMODB_TABLE" "SNS_TOPIC_ARN"

    ensure_event_source_mapping "$LAMBDA_NAME" "$QUEUE_ARN" "$AWS_REGION"

    rm -f "lambda_deploy_${OPERATION}.zip"
}

deploy_lifecycle_handler "cancel"
deploy_lifecycle_handler "update"
