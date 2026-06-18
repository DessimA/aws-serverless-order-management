#!/usr/bin/env bash
set -euo pipefail

if [ -f ../.env ]; then
    export $(grep -v '^#' ../.env | xargs)
else
    echo "Erro: Arquivo .env nao encontrado na raiz."
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_NAME="order-api-validator-role-$RESOURCE_SUFFIX"
FIFO_QUEUE_NAME="order-ingestion-queue-$RESOURCE_SUFFIX.fifo"
DLQ_NAME="order-ingestion-dlq-$RESOURCE_SUFFIX.fifo"
LAMBDA_NAME="order-api-validator-$RESOURCE_SUFFIX"
API_NAME="order-ingestion-api-$RESOURCE_SUFFIX"
BUS_NAME="pedidos-event-bus-$RESOURCE_SUFFIX"

echo "--- Provisioning API Ingestion Flow & Event Bus ---"

# 1. Garantir existencia do Event Bus (Centralizador)
if ! aws events describe-event-bus --name "$BUS_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "Criando Custom Event Bus: $BUS_NAME..."
    aws events create-event-bus --name "$BUS_NAME" --region "$AWS_REGION"
fi
BUS_ARN=$(aws events describe-event-bus --name "$BUS_NAME" --region "$AWS_REGION" --query Arn --output text)

# 2. IAM Role
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

# 3. SQS FIFO Queues (Mantidas para resiliencia/backup)
if ! aws sqs get-queue-url --queue-name "$DLQ_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws sqs create-queue --queue-name "$DLQ_NAME" --attributes "{\"FifoQueue\":\"true\"}" --region "$AWS_REGION"
fi
DLQ_ARN=$(aws sqs get-queue-attributes --queue-url "$(aws sqs get-queue-url --queue-name "$DLQ_NAME" --region "$AWS_REGION" --query QueueUrl --output text)" --attribute-names QueueArn --query Attributes.QueueArn --output text --region "$AWS_REGION")

if ! aws sqs get-queue-url --queue-name "$FIFO_QUEUE_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws sqs create-queue --queue-name "$FIFO_QUEUE_NAME" --attributes "{\"FifoQueue\":\"true\",\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"$DLQ_ARN\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"}" --region "$AWS_REGION"
fi
SQS_URL=$(aws sqs get-queue-url --queue-name "$FIFO_QUEUE_NAME" --region "$AWS_REGION" --query QueueUrl --output text)
SQS_ARN=$(aws sqs get-queue-attributes --queue-url "$SQS_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text --region "$AWS_REGION")

# 4. Permissoes: SQS e EventBridge
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "OrderIngestionAccess" --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
        {\"Effect\": \"Allow\", \"Action\": \"sqs:SendMessage\", \"Resource\": \"$SQS_ARN\"},
        {\"Effect\": \"Allow\", \"Action\": \"events:PutEvents\", \"Resource\": \"$BUS_ARN\"}
    ]
}"

# 5. Lambda Deployment
cd ../src/api_validator
zip -q ../../scripts/lambda_deploy.zip index.py
cd ../../scripts

if ! aws lambda get-function --function-name "$LAMBDA_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws lambda create-function --function-name "$LAMBDA_NAME" --runtime python3.12 --role "arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME" --handler index.lambda_handler --zip-file fileb://lambda_deploy.zip --region "$AWS_REGION"
    aws lambda wait function-active --function-name "$LAMBDA_NAME" --region "$AWS_REGION"
else
    aws lambda update-function-code --function-name "$LAMBDA_NAME" --zip-file fileb://lambda_deploy.zip --region "$AWS_REGION"
    aws lambda wait function-updated --function-name "$LAMBDA_NAME" --region "$AWS_REGION"
fi

aws lambda update-function-configuration --function-name "$LAMBDA_NAME" --environment "Variables={SQS_QUEUE_URL=$SQS_URL,EVENT_BUS_NAME=$BUS_NAME}" --region "$AWS_REGION"
rm lambda_deploy.zip

# 6. API Gateway
API_ID=$(aws apigateway get-rest-apis --region "$AWS_REGION" --query "items[?name=='$API_NAME'].id" --output text)
if [ -z "$API_ID" ] || [ "$API_ID" == "None" ]; then
    API_ID=$(aws apigateway create-rest-api --name "$API_NAME" --region "$AWS_REGION" --query id --output text)
fi
ROOT_ID=$(aws apigateway get-resources --rest-api-id "$API_ID" --region "$AWS_REGION" --query "items[?path=='/'].id" --output text)
RES_ID=$(aws apigateway get-resources --rest-api-id "$API_ID" --region "$AWS_REGION" --query "items[?path=='/orders'].id" --output text)
if [ -z "$RES_ID" ] || [ "$RES_ID" == "None" ]; then
    RES_ID=$(aws apigateway create-resource --rest-api-id "$API_ID" --parent-id "$ROOT_ID" --path-part "orders" --region "$AWS_REGION" --query id --output text)
fi
if ! aws apigateway get-method --rest-api-id "$API_ID" --resource-id "$RES_ID" --http-method POST --region "$AWS_REGION" >/dev/null 2>&1; then
    aws apigateway put-method --rest-api-id "$API_ID" --resource-id "$RES_ID" --http-method POST --authorization-type "NONE" --region "$AWS_REGION"
fi
aws apigateway put-integration --rest-api-id "$API_ID" --resource-id "$RES_ID" --http-method POST --type AWS_PROXY --integration-http-method POST --uri "arn:aws:apigateway:$AWS_REGION:lambda:path/2015-03-31/functions/arn:aws:lambda:$AWS_REGION:$ACCOUNT_ID:function:$LAMBDA_NAME/invocations" --region "$AWS_REGION"
if ! aws lambda get-policy --function-name "$LAMBDA_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws lambda add-permission --function-name "$LAMBDA_NAME" --statement-id apigateway --action lambda:InvokeFunction --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:$AWS_REGION:$ACCOUNT_ID:$API_ID/*" --region "$AWS_REGION"
fi
aws apigateway create-deployment --rest-api-id "$API_ID" --stage-name prod --region "$AWS_REGION"