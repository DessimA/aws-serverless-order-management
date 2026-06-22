#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/lib.sh"

load_env "$SCRIPT_DIR/.env"
validate_env "RESOURCE_SUFFIX" "AWS_REGION"

echo "=== INICIANDO LIMPEZA PARA SUFFIX: $RESOURCE_SUFFIX ==="

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# === S3 Bucket (empty + delete) ===
S3_BUCKET="order-files-bucket-${RESOURCE_SUFFIX}"
if aws s3api head-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION" 2>/dev/null; then
    aws s3 rm "s3://${S3_BUCKET}" --recursive --region "$AWS_REGION" 2>/dev/null || true
    aws s3api delete-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION" || true
    echo "S3 bucket deleted: $S3_BUCKET"
fi

FRONTEND_BUCKET="order-frontend-${RESOURCE_SUFFIX}"
if aws s3api head-bucket --bucket "$FRONTEND_BUCKET" --region "$AWS_REGION" 2>/dev/null; then
    aws s3 rm "s3://${FRONTEND_BUCKET}" --recursive --region "$AWS_REGION" 2>/dev/null || true
    aws s3api delete-bucket --bucket "$FRONTEND_BUCKET" --region "$AWS_REGION" || true
    echo "Frontend S3 bucket deleted: $FRONTEND_BUCKET"
fi

# === Event Bus ===
BUS_NAME="orders-event-bus-${RESOURCE_SUFFIX}"
if aws events describe-event-bus --name "$BUS_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    # Must remove all rules+targets before deleting bus
    for rule in $(aws events list-rules --event-bus-name "$BUS_NAME" --region "$AWS_REGION" --query "Rules[].Name" --output text); do
        TARGET_ARNS=$(aws events list-targets-by-rule --rule "$rule" --event-bus-name "$BUS_NAME" --region "$AWS_REGION" --query "Targets[].Arn" --output text 2>/dev/null || true)
        if [ -n "$TARGET_ARNS" ]; then
            TARGET_IDS=$(aws events list-targets-by-rule --rule "$rule" --event-bus-name "$BUS_NAME" --region "$AWS_REGION" --query "Targets[].Id" --output text 2>/dev/null || true)
            if [ -n "$TARGET_IDS" ]; then
                aws events remove-targets --rule "$rule" --event-bus-name "$BUS_NAME" --ids $TARGET_IDS --region "$AWS_REGION" 2>/dev/null || true
            fi
        fi
        aws events delete-rule --name "$rule" --event-bus-name "$BUS_NAME" --region "$AWS_REGION" 2>/dev/null || true
    done
    aws events delete-event-bus --name "$BUS_NAME" --region "$AWS_REGION" || true
    echo "Event bus deleted: $BUS_NAME"
fi

# === Lambda Functions ===
for name in "order-persister-${RESOURCE_SUFFIX}" "order-lifecycle-cancel-${RESOURCE_SUFFIX}" "order-lifecycle-update-${RESOURCE_SUFFIX}" "order-file-validator-${RESOURCE_SUFFIX}" "order-pre-validator-${RESOURCE_SUFFIX}" "order-validator-${RESOURCE_SUFFIX}" "order-reader-${RESOURCE_SUFFIX}" "test-controller-${RESOURCE_SUFFIX}" "customer-auth-${RESOURCE_SUFFIX}"; do
    if aws lambda get-function --function-name "$name" --region "$AWS_REGION" >/dev/null 2>&1; then
        REMAINING_LAMBDAS=$(aws lambda list-event-source-mappings --function-name "$name" --region "$AWS_REGION" --query "EventSourceMappings[].UUID" --output text 2>/dev/null || true)
        for UUID in $REMAINING_LAMBDAS; do
            aws lambda delete-event-source-mapping --uuid "$UUID" --region "$AWS_REGION" 2>/dev/null || true
        done
        aws lambda delete-function --function-name "$name" --region "$AWS_REGION" || true
        echo "Lambda deleted: $name"
    fi
    aws logs delete-log-group --log-group-name "/aws/lambda/$name" --region "$AWS_REGION" 2>/dev/null || true
done

# === IAM Roles ===
for suffix in "order-pre-validator-role-${RESOURCE_SUFFIX}" "order-validator-role-${RESOURCE_SUFFIX}" "order-file-validator-role-${RESOURCE_SUFFIX}" "order-persister-role-${RESOURCE_SUFFIX}" "order-lifecycle-cancel-role-${RESOURCE_SUFFIX}" "order-lifecycle-update-role-${RESOURCE_SUFFIX}" "order-reader-role-${RESOURCE_SUFFIX}" "test-controller-role-${RESOURCE_SUFFIX}" "customer-auth-role-${RESOURCE_SUFFIX}"; do
    ROLE_NAME="$suffix"
    if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
        ATTACHED_POLICIES=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null || true)
        for policy_arn in $ATTACHED_POLICIES; do
            aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$policy_arn" 2>/dev/null || true
        done
        INLINE_POLICY_NAMES=$(aws iam list-role-policies --role-name "$ROLE_NAME" --query "PolicyNames" --output text 2>/dev/null || true)
        for policy_name in $INLINE_POLICY_NAMES; do
            aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$policy_name" 2>/dev/null || true
        done
        aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true
        echo "IAM Role deleted: $ROLE_NAME"
    fi
done

# === SQS Queues ===
# Standard queues
for name in "order-persister-queue-${RESOURCE_SUFFIX}" "order-persister-dlq-${RESOURCE_SUFFIX}" "order-s3-batch-queue-${RESOURCE_SUFFIX}" "order-s3-batch-dlq-${RESOURCE_SUFFIX}" "cancel-order-queue-${RESOURCE_SUFFIX}" "cancel-order-dlq-${RESOURCE_SUFFIX}" "update-order-queue-${RESOURCE_SUFFIX}" "update-order-dlq-${RESOURCE_SUFFIX}"; do
    QUEUE_URL=$(aws sqs get-queue-url --queue-name "$name" --region "$AWS_REGION" --query QueueUrl --output text 2>/dev/null || true)
    if [ -n "$QUEUE_URL" ] && [ "$QUEUE_URL" != "None" ]; then
        aws sqs delete-queue --queue-url "$QUEUE_URL" --region "$AWS_REGION" 2>/dev/null || true
        echo "SQS queue deleted: $name"
    fi
done
# FIFO queues (retain .fifo suffix)
for name in "order-validation-buffer-${RESOURCE_SUFFIX}.fifo" "order-validation-dlq-${RESOURCE_SUFFIX}.fifo"; do
    QUEUE_URL=$(aws sqs get-queue-url --queue-name "$name" --region "$AWS_REGION" --query QueueUrl --output text 2>/dev/null || true)
    if [ -n "$QUEUE_URL" ] && [ "$QUEUE_URL" != "None" ]; then
        aws sqs delete-queue --queue-url "$QUEUE_URL" --region "$AWS_REGION" 2>/dev/null || true
        echo "SQS queue deleted: $name"
    fi
done

# === DynamoDB Tables ===
for name in "order-production-data-${RESOURCE_SUFFIX}" "order-batch-audit-${RESOURCE_SUFFIX}" "customer-data-${RESOURCE_SUFFIX}"; do
    if aws dynamodb describe-table --table-name "$name" --region "$AWS_REGION" >/dev/null 2>&1; then
        aws dynamodb delete-table --table-name "$name" --region "$AWS_REGION" || true
        echo "DynamoDB table deleted: $name"
    fi
done

# === API Gateway ===
API_ID=$(aws apigateway get-rest-apis --region "$AWS_REGION" --query "items[?name=='order-ingestion-api-${RESOURCE_SUFFIX}'].id" --output text 2>/dev/null || true)
if [ -n "$API_ID" ] && [ "$API_ID" != "None" ]; then
    aws apigateway delete-rest-api --rest-api-id "$API_ID" --region "$AWS_REGION" || true
    echo "API Gateway deleted: order-ingestion-api-${RESOURCE_SUFFIX}"
fi

# === SNS Topic ===
TOPIC_ARN=$(aws sns list-topics --region "$AWS_REGION" --query "Topics[?contains(TopicArn, 'order-notifications-${RESOURCE_SUFFIX}')].TopicArn" --output text 2>/dev/null || true)
if [ -n "$TOPIC_ARN" ] && [ "$TOPIC_ARN" != "None" ]; then
    aws sns delete-topic --topic-arn "$TOPIC_ARN" --region "$AWS_REGION" || true
    echo "SNS topic deleted: order-notifications-${RESOURCE_SUFFIX}"
fi

# === CloudWatch Alarms ===
for ALARM_NAME in "dlq-alarm-validation-${RESOURCE_SUFFIX}" "dlq-alarm-persister-${RESOURCE_SUFFIX}" "dlq-alarm-cancel-${RESOURCE_SUFFIX}" "dlq-alarm-update-${RESOURCE_SUFFIX}" "dlq-alarm-s3-batch-${RESOURCE_SUFFIX}"; do
    aws cloudwatch delete-alarms --alarm-names "$ALARM_NAME" --region "$AWS_REGION" 2>/dev/null || true
    echo "CloudWatch Alarm deleted: $ALARM_NAME"
done

# === API Key + Usage Plan ===
API_KEY_NAME="order-ingestion-api-key-${RESOURCE_SUFFIX}"
USAGE_PLAN_NAME="order-ingestion-usage-plan-${RESOURCE_SUFFIX}"
USAGE_PLAN_ID=$(aws apigateway get-usage-plans --region "$AWS_REGION" --query "items[?name=='$USAGE_PLAN_NAME'].id" --output text 2>/dev/null || true)
API_KEY_ID=$(aws apigateway get-api-keys --region "$AWS_REGION" --query "items[?name=='$API_KEY_NAME'].id" --output text 2>/dev/null || true)

if [ -n "$USAGE_PLAN_ID" ] && [ "$USAGE_PLAN_ID" != "None" ] && [ -n "$API_KEY_ID" ] && [ "$API_KEY_ID" != "None" ]; then
    aws apigateway delete-usage-plan-key --usage-plan-id "$USAGE_PLAN_ID" --key-id "$API_KEY_ID" --region "$AWS_REGION" 2>/dev/null || true
fi

if [ -n "$API_KEY_ID" ] && [ "$API_KEY_ID" != "None" ]; then
    aws apigateway delete-api-key --api-key "$API_KEY_ID" --region "$AWS_REGION" 2>/dev/null || true
    echo "API Key deleted: $API_KEY_NAME"
fi

if [ -n "$USAGE_PLAN_ID" ] && [ "$USAGE_PLAN_ID" != "None" ]; then
    aws apigateway delete-usage-plan --usage-plan-id "$USAGE_PLAN_ID" --region "$AWS_REGION" 2>/dev/null || true
    echo "Usage Plan deleted: $USAGE_PLAN_NAME"
fi

# === .api-key file ===
rm -f "$SCRIPT_DIR/.api-key" 2>/dev/null || true
echo ".api-key file removed."

# === .jwt-secret file ===
rm -f "$SCRIPT_DIR/scripts/.jwt-secret" 2>/dev/null || true
echo ".jwt-secret file removed."

echo ""
echo "=== LIMPEZA CONCLUIDA PARA SUFFIX: $RESOURCE_SUFFIX ==="
