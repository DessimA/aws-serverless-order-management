#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

load_env "$SCRIPT_DIR/../.env"
validate_env "AWS_REGION" "RESOURCE_SUFFIX" "NOTIFICATION_EMAIL"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# === Resource Names ===
EVENT_BUS_NAME="orders-event-bus-$RESOURCE_SUFFIX"
SNS_TOPIC_NAME="order-notifications-$RESOURCE_SUFFIX"

VALIDATION_BUFFER_QUEUE="order-validation-buffer-$RESOURCE_SUFFIX.fifo"
VALIDATION_DLQ="order-validation-dlq-$RESOURCE_SUFFIX.fifo"

PRE_ROLE_NAME="order-pre-validator-role-$RESOURCE_SUFFIX"
PRE_LAMBDA_NAME="order-pre-validator-$RESOURCE_SUFFIX"

VAL_ROLE_NAME="order-validator-role-$RESOURCE_SUFFIX"
VAL_LAMBDA_NAME="order-validator-$RESOURCE_SUFFIX"

REST_API_NAME="order-ingestion-api-$RESOURCE_SUFFIX"

# === Event Bus ===
if ! aws events describe-event-bus --name "$EVENT_BUS_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws events create-event-bus --name "$EVENT_BUS_NAME" --region "$AWS_REGION"
fi
EVENT_BUS_ARN=$(aws events describe-event-bus --name "$EVENT_BUS_NAME" --region "$AWS_REGION" --query Arn --output text)
validate_not_empty "EVENT_BUS_ARN" "$EVENT_BUS_ARN" "EventBus ARN"

# === SNS Topic (shared across flows) ===
if ! aws sns get-topic-attributes --topic-arn "arn:aws:sns:$AWS_REGION:$ACCOUNT_ID:$SNS_TOPIC_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws sns create-topic --name "$SNS_TOPIC_NAME" --region "$AWS_REGION"
fi
SNS_TOPIC_ARN=$(aws sns get-topic-attributes --topic-arn "arn:aws:sns:$AWS_REGION:$ACCOUNT_ID:$SNS_TOPIC_NAME" --query Attributes.TopicArn --output text --region "$AWS_REGION")
validate_not_empty "SNS_TOPIC_ARN" "$SNS_TOPIC_ARN" "SNS Topic ARN"
sns_subscribe_email "$SNS_TOPIC_ARN" "$NOTIFICATION_EMAIL" "$AWS_REGION"

# ================================================================
# LAMBDA PRE-VALIDATOR (LambdaPre: API Gateway → SQS FIFO)
# ================================================================

ensure_iam_lambda_role "$PRE_ROLE_NAME"

VALIDATION_DLQ_ARN=$(ensure_sqs_dlq "$VALIDATION_DLQ" "$AWS_REGION" "true")
validate_not_empty "VALIDATION_DLQ_ARN" "$VALIDATION_DLQ_ARN" "Validation DLQ ARN"

ensure_sqs_queue "$VALIDATION_BUFFER_QUEUE" "$VALIDATION_DLQ_ARN" "$AWS_REGION" "true" "true"
VALIDATION_BUFFER_URL="$QUEUE_URL"
VALIDATION_BUFFER_ARN="$QUEUE_ARN"

# Inline policy for LambdaPre: sqs:SendMessage
aws iam put-role-policy --role-name "$PRE_ROLE_NAME" --policy-name "PreValidatorSQSAccess" --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sqs:SendMessage\",\"Resource\":\"$VALIDATION_BUFFER_ARN\"}]}"

# === Deploy LambdaPre ===
PKG_DIR_PRE=$(mktemp -d)
cp ../src/pre_validator/index.py "$PKG_DIR_PRE/"
mkdir -p "$PKG_DIR_PRE/common"
cp ../src/common/*.py "$PKG_DIR_PRE/common/"
cd "$PKG_DIR_PRE"
zip -qr "$SCRIPT_DIR/lambda_deploy_pre.zip" .
cd "$SCRIPT_DIR"
rm -rf "$PKG_DIR_PRE"

ensure_lambda_function "$PRE_LAMBDA_NAME" "$PRE_ROLE_NAME" "index.lambda_handler" "lambda_deploy_pre.zip" "$AWS_REGION" "$ACCOUNT_ID" "SQS_QUEUE_URL=$VALIDATION_BUFFER_URL"
validate_lambda_config "$PRE_LAMBDA_NAME" "$AWS_REGION" "SQS_QUEUE_URL"
rm -f lambda_deploy_pre.zip

# ================================================================
# LAMBDA VALIDATOR (LambdaVal: SQS FIFO → EventBridge + SNS)
# ================================================================

ensure_iam_lambda_role "$VAL_ROLE_NAME"
aws iam put-role-policy --role-name "$VAL_ROLE_NAME" --policy-name "ValidatorAccess" --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"events:PutEvents\",\"Resource\":\"$EVENT_BUS_ARN\"},{\"Effect\":\"Allow\",\"Action\":\"sns:Publish\",\"Resource\":\"$SNS_TOPIC_ARN\"},{\"Effect\":\"Allow\",\"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:GetQueueAttributes\"],\"Resource\":\"$VALIDATION_BUFFER_ARN\"}]}"

# === Deploy LambdaVal ===
PKG_DIR_VAL=$(mktemp -d)
cp ../src/order_validator/index.py "$PKG_DIR_VAL/"
mkdir -p "$PKG_DIR_VAL/common"
cp ../src/common/*.py "$PKG_DIR_VAL/common/"
cd "$PKG_DIR_VAL"
zip -qr "$SCRIPT_DIR/lambda_deploy_val.zip" .
cd "$SCRIPT_DIR"
rm -rf "$PKG_DIR_VAL"

ensure_lambda_function "$VAL_LAMBDA_NAME" "$VAL_ROLE_NAME" "index.lambda_handler" "lambda_deploy_val.zip" "$AWS_REGION" "$ACCOUNT_ID" "EVENT_BUS_NAME=$EVENT_BUS_NAME,SNS_TOPIC_ARN=$SNS_TOPIC_ARN"
validate_lambda_config "$VAL_LAMBDA_NAME" "$AWS_REGION" "EVENT_BUS_NAME" "SNS_TOPIC_ARN"
rm -f lambda_deploy_val.zip

ensure_event_source_mapping "$VAL_LAMBDA_NAME" "$VALIDATION_BUFFER_ARN" "$AWS_REGION"

# ================================================================
# API GATEWAY → LambdaPre
# ================================================================

REST_API_ID=$(aws apigateway get-rest-apis --region "$AWS_REGION" --query "items[?name=='$REST_API_NAME'].id" --output text)
if [ -z "$REST_API_ID" ] || [ "$REST_API_ID" == "None" ]; then
    REST_API_ID=$(aws apigateway create-rest-api --name "$REST_API_NAME" --region "$AWS_REGION" --query id --output text)
fi
validate_not_empty "REST_API_ID" "$REST_API_ID" "REST API ID"
API_ROOT_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$REST_API_ID" --region "$AWS_REGION" --query "items[?path=='/'].id" --output text)
ORDERS_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$REST_API_ID" --region "$AWS_REGION" --query "items[?path=='/orders'].id" --output text)
if [ -z "$ORDERS_RESOURCE_ID" ] || [ "$ORDERS_RESOURCE_ID" == "None" ]; then
    ORDERS_RESOURCE_ID=$(aws apigateway create-resource --rest-api-id "$REST_API_ID" --parent-id "$API_ROOT_RESOURCE_ID" --path-part "orders" --region "$AWS_REGION" --query id --output text)
fi
validate_not_empty "ORDERS_RESOURCE_ID" "$ORDERS_RESOURCE_ID" "Resource /orders"

# POST method
if ! aws apigateway get-method --rest-api-id "$REST_API_ID" --resource-id "$ORDERS_RESOURCE_ID" --http-method POST --region "$AWS_REGION" >/dev/null 2>&1; then
    aws apigateway put-method --rest-api-id "$REST_API_ID" --resource-id "$ORDERS_RESOURCE_ID" --http-method POST --authorization-type "NONE" --region "$AWS_REGION"
fi

setup_api_cors "$REST_API_ID" "$ORDERS_RESOURCE_ID" "$AWS_REGION"

# POST integration → LambdaPre
aws apigateway get-integration --rest-api-id "$REST_API_ID" --resource-id "$ORDERS_RESOURCE_ID" --http-method POST --region "$AWS_REGION" >/dev/null 2>&1 || \
aws apigateway put-integration --rest-api-id "$REST_API_ID" --resource-id "$ORDERS_RESOURCE_ID" --http-method POST --type AWS_PROXY --integration-http-method POST --uri "arn:aws:apigateway:$AWS_REGION:lambda:path/2015-03-31/functions/arn:aws:lambda:$AWS_REGION:$ACCOUNT_ID:function:$PRE_LAMBDA_NAME/invocations" --region "$AWS_REGION"
aws lambda remove-permission --function-name "$PRE_LAMBDA_NAME" --statement-id apigateway --region "$AWS_REGION" 2>/dev/null || true
aws lambda add-permission --function-name "$PRE_LAMBDA_NAME" --statement-id apigateway --action lambda:InvokeFunction --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:$AWS_REGION:$ACCOUNT_ID:$REST_API_ID/*/POST/orders" --region "$AWS_REGION"
aws apigateway create-deployment --rest-api-id "$REST_API_ID" --stage-name prod --region "$AWS_REGION"

echo "API Flow deployment complete."
echo "SNS Topic ARN: $SNS_TOPIC_ARN"
