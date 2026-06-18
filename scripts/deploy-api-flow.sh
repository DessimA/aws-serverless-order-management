#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

load_env "$SCRIPT_DIR/../.env"
validate_env "AWS_REGION" "RESOURCE_SUFFIX"

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

# === SNS Topic (shared across flows) ===
if ! aws sns get-topic-attributes --topic-arn "arn:aws:sns:$AWS_REGION:$ACCOUNT_ID:$SNS_TOPIC_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws sns create-topic --name "$SNS_TOPIC_NAME" --region "$AWS_REGION"
fi
SNS_TOPIC_ARN=$(aws sns get-topic-attributes --topic-arn "arn:aws:sns:$AWS_REGION:$ACCOUNT_ID:$SNS_TOPIC_NAME" --query Attributes.TopicArn --output text --region "$AWS_REGION")

# ================================================================
# LAMBDA PRE-VALIDATOR (LambdaPre: API Gateway → SQS FIFO)
# ================================================================

# === IAM Role for LambdaPre ===
if ! aws iam get-role --role-name "$PRE_ROLE_NAME" >/dev/null 2>&1; then
    aws iam create-role --role-name "$PRE_ROLE_NAME" --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
    aws iam attach-role-policy --role-name "$PRE_ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    wait_for_iam_role "$PRE_ROLE_NAME"
fi

# === SQS FIFO Queues for API buffer ===
if ! aws sqs get-queue-url --queue-name "$VALIDATION_DLQ" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws sqs create-queue --queue-name "$VALIDATION_DLQ" --attributes "{\"FifoQueue\":\"true\"}" --region "$AWS_REGION"
fi
VALIDATION_DLQ_ARN=$(aws sqs get-queue-attributes --queue-url "$(aws sqs get-queue-url --queue-name "$VALIDATION_DLQ" --region "$AWS_REGION" --query QueueUrl --output text)" --attribute-names QueueArn --query Attributes.QueueArn --output text --region "$AWS_REGION")

if ! aws sqs get-queue-url --queue-name "$VALIDATION_BUFFER_QUEUE" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws sqs create-queue --queue-name "$VALIDATION_BUFFER_QUEUE" --attributes "{\"FifoQueue\":\"true\",\"ContentBasedDeduplication\":\"true\",\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"$VALIDATION_DLQ_ARN\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"}" --region "$AWS_REGION"
fi
VALIDATION_BUFFER_URL=$(aws sqs get-queue-url --queue-name "$VALIDATION_BUFFER_QUEUE" --region "$AWS_REGION" --query QueueUrl --output text)
VALIDATION_BUFFER_ARN=$(aws sqs get-queue-attributes --queue-url "$VALIDATION_BUFFER_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text --region "$AWS_REGION")
wait_for_sqs_queue "$VALIDATION_BUFFER_QUEUE" "$AWS_REGION"

# Inline policy for LambdaPre: sqs:SendMessage
aws iam put-role-policy --role-name "$PRE_ROLE_NAME" --policy-name "PreValidatorSQSAccess" --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sqs:SendMessage\",\"Resource\":\"$VALIDATION_BUFFER_ARN\"}]}"

# === Deploy LambdaPre ===
cd ../src/pre_validator
zip -q ../../scripts/lambda_deploy_pre.zip index.py
cd ../../scripts

if ! aws lambda get-function --function-name "$PRE_LAMBDA_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "Criando Lambda $PRE_LAMBDA_NAME..."
    for i in {1..3}; do
        aws lambda create-function --function-name "$PRE_LAMBDA_NAME" --runtime python3.12 --role "arn:aws:iam::$ACCOUNT_ID:role/$PRE_ROLE_NAME" --handler index.lambda_handler --zip-file fileb://lambda_deploy_pre.zip --region "$AWS_REGION" && break || sleep 10
    done
    aws lambda wait function-active-v2 --function-name "$PRE_LAMBDA_NAME" --region "$AWS_REGION"
else
    aws lambda update-function-code --function-name "$PRE_LAMBDA_NAME" --zip-file fileb://lambda_deploy_pre.zip --region "$AWS_REGION"
    aws lambda wait function-updated-v2 --function-name "$PRE_LAMBDA_NAME" --region "$AWS_REGION"
fi

aws lambda update-function-configuration --function-name "$PRE_LAMBDA_NAME" --environment "Variables={SQS_QUEUE_URL=$VALIDATION_BUFFER_URL}" --region "$AWS_REGION"
rm -f lambda_deploy_pre.zip

# ================================================================
# LAMBDA VALIDATOR (LambdaVal: SQS FIFO → EventBridge + SNS)
# ================================================================

# === IAM Role for LambdaVal ===
if ! aws iam get-role --role-name "$VAL_ROLE_NAME" >/dev/null 2>&1; then
    aws iam create-role --role-name "$VAL_ROLE_NAME" --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
    aws iam attach-role-policy --role-name "$VAL_ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    wait_for_iam_role "$VAL_ROLE_NAME"
fi
aws iam put-role-policy --role-name "$VAL_ROLE_NAME" --policy-name "ValidatorAccess" --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"events:PutEvents\",\"Resource\":\"$EVENT_BUS_ARN\"},{\"Effect\":\"Allow\",\"Action\":\"sns:Publish\",\"Resource\":\"$SNS_TOPIC_ARN\"},{\"Effect\":\"Allow\",\"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:GetQueueAttributes\"],\"Resource\":\"$VALIDATION_BUFFER_ARN\"}]}"

# === Deploy LambdaVal ===
cd ../src/order_validator
zip -q ../../scripts/lambda_deploy_val.zip index.py
cd ../../scripts

if ! aws lambda get-function --function-name "$VAL_LAMBDA_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "Criando Lambda $VAL_LAMBDA_NAME..."
    for i in {1..3}; do
        aws lambda create-function --function-name "$VAL_LAMBDA_NAME" --runtime python3.12 --role "arn:aws:iam::$ACCOUNT_ID:role/$VAL_ROLE_NAME" --handler index.lambda_handler --zip-file fileb://lambda_deploy_val.zip --region "$AWS_REGION" && break || sleep 10
    done
    aws lambda wait function-active-v2 --function-name "$VAL_LAMBDA_NAME" --region "$AWS_REGION"
else
    aws lambda update-function-code --function-name "$VAL_LAMBDA_NAME" --zip-file fileb://lambda_deploy_val.zip --region "$AWS_REGION"
    aws lambda wait function-updated-v2 --function-name "$VAL_LAMBDA_NAME" --region "$AWS_REGION"
fi

aws lambda update-function-configuration --function-name "$VAL_LAMBDA_NAME" --environment "Variables={EVENT_BUS_NAME=$EVENT_BUS_NAME,SNS_TOPIC_ARN=$SNS_TOPIC_ARN}" --region "$AWS_REGION"
rm -f lambda_deploy_val.zip

# === SQS FIFO → LambdaVal event source mapping ===
if ! aws lambda list-event-source-mappings --function-name "$VAL_LAMBDA_NAME" --event-source-arn "$VALIDATION_BUFFER_ARN" --region "$AWS_REGION" --query "EventSourceMappings[0]" --output text >/dev/null 2>&1; then
    aws lambda create-event-source-mapping --function-name "$VAL_LAMBDA_NAME" --batch-size 5 --event-source-arn "$VALIDATION_BUFFER_ARN" --region "$AWS_REGION"
fi

# ================================================================
# API GATEWAY → LambdaPre
# ================================================================

REST_API_ID=$(aws apigateway get-rest-apis --region "$AWS_REGION" --query "items[?name=='$REST_API_NAME'].id" --output text)
if [ -z "$REST_API_ID" ] || [ "$REST_API_ID" == "None" ]; then
    REST_API_ID=$(aws apigateway create-rest-api --name "$REST_API_NAME" --region "$AWS_REGION" --query id --output text)
fi
API_ROOT_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$REST_API_ID" --region "$AWS_REGION" --query "items[?path=='/'].id" --output text)
ORDERS_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$REST_API_ID" --region "$AWS_REGION" --query "items[?path=='/orders'].id" --output text)
if [ -z "$ORDERS_RESOURCE_ID" ] || [ "$ORDERS_RESOURCE_ID" == "None" ]; then
    ORDERS_RESOURCE_ID=$(aws apigateway create-resource --rest-api-id "$REST_API_ID" --parent-id "$API_ROOT_RESOURCE_ID" --path-part "orders" --region "$AWS_REGION" --query id --output text)
fi

# POST method
if ! aws apigateway get-method --rest-api-id "$REST_API_ID" --resource-id "$ORDERS_RESOURCE_ID" --http-method POST --region "$AWS_REGION" >/dev/null 2>&1; then
    aws apigateway put-method --rest-api-id "$REST_API_ID" --resource-id "$ORDERS_RESOURCE_ID" --http-method POST --authorization-type "NONE" --region "$AWS_REGION"
fi

# OPTIONS (CORS)
if ! aws apigateway get-method --rest-api-id "$REST_API_ID" --resource-id "$ORDERS_RESOURCE_ID" --http-method OPTIONS --region "$AWS_REGION" >/dev/null 2>&1; then
    aws apigateway put-method --rest-api-id "$REST_API_ID" --resource-id "$ORDERS_RESOURCE_ID" --http-method OPTIONS --authorization-type "NONE" --region "$AWS_REGION"
fi
aws apigateway put-method-response --rest-api-id "$REST_API_ID" --resource-id "$ORDERS_RESOURCE_ID" --http-method OPTIONS --status-code 200 \
    --response-parameters "method.response.header.Access-Control-Allow-Headers=true,method.response.header.Access-Control-Allow-Methods=true,method.response.header.Access-Control-Allow-Origin=true" \
    --region "$AWS_REGION"
aws apigateway put-integration --rest-api-id "$REST_API_ID" --resource-id "$ORDERS_RESOURCE_ID" --http-method OPTIONS --type MOCK \
    --request-templates '{"application/json":"{\"statusCode\":200}"}' --region "$AWS_REGION"
aws apigateway put-integration-response --rest-api-id "$REST_API_ID" --resource-id "$ORDERS_RESOURCE_ID" --http-method OPTIONS --status-code 200 \
    --response-parameters "method.response.header.Access-Control-Allow-Headers='*',method.response.header.Access-Control-Allow-Methods='*',method.response.header.Access-Control-Allow-Origin='*'" \
    --region "$AWS_REGION"

# POST integration → LambdaPre
aws apigateway put-integration --rest-api-id "$REST_API_ID" --resource-id "$ORDERS_RESOURCE_ID" --http-method POST --type AWS_PROXY --integration-http-method POST --uri "arn:aws:apigateway:$AWS_REGION:lambda:path/2015-03-31/functions/arn:aws:lambda:$AWS_REGION:$ACCOUNT_ID:function:$PRE_LAMBDA_NAME/invocations" --region "$AWS_REGION"
if ! aws lambda get-policy --function-name "$PRE_LAMBDA_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws lambda add-permission --function-name "$PRE_LAMBDA_NAME" --statement-id apigateway --action lambda:InvokeFunction --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:$AWS_REGION:$ACCOUNT_ID:$REST_API_ID/*" --region "$AWS_REGION"
fi
aws apigateway create-deployment --rest-api-id "$REST_API_ID" --stage-name prod --region "$AWS_REGION"

echo "API Flow deployment complete."
echo "SNS Topic ARN: $SNS_TOPIC_ARN"
