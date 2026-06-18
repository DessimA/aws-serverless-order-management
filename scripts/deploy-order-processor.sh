#!/usr/bin/env bash
set -euo pipefail

if [ -f ../.env ]; then export $(grep -v '^#' ../.env | xargs); fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="$AWS_REGION"
SUFFIX="$RESOURCE_SUFFIX"

ROLE_NAME="order-final-processor-role-$SUFFIX"
TABLE_NAME="orders-production-db-$SUFFIX"
QUEUE_NAME="orders-pending-processor-queue-$SUFFIX"
DLQ_NAME="orders-pending-processor-dlq-$SUFFIX"
LAMBDA_NAME="order-final-processor-$SUFFIX"
BUS_NAME="pedidos-event-bus-$SUFFIX"
RULE_NAME="order-validated-routing-rule-$SUFFIX"

# 1. IAM Role com pausa
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
    aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    echo "Aguardando propagacao do IAM Role..."
    sleep 15
fi

# 2. DynamoDB & SQS
if ! aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$REGION" >/dev/null 2>&1; then
    aws dynamodb create-table --table-name "$TABLE_NAME" --attribute-definitions AttributeName=orderId,AttributeType=S --key-schema AttributeName=orderId,KeyType=HASH --billing-mode PAY_PER_REQUEST --region "$REGION"
fi
DYNAMO_ARN="arn:aws:dynamodb:$REGION:$ACCOUNT_ID:table/$TABLE_NAME"

if ! aws sqs get-queue-url --queue-name "$DLQ_NAME" --region "$REGION" >/dev/null 2>&1; then
    aws sqs create-queue --queue-name "$DLQ_NAME" --region "$REGION"
fi
DLQ_ARN=$(aws sqs get-queue-attributes --queue-url "$(aws sqs get-queue-url --queue-name "$DLQ_NAME" --region "$REGION" --query QueueUrl --output text)" --attribute-names QueueArn --query Attributes.QueueArn --output text --region "$REGION")

if ! aws sqs get-queue-url --queue-name "$QUEUE_NAME" --region "$REGION" >/dev/null 2>&1; then
    aws sqs create-queue --queue-name "$QUEUE_NAME" --attributes "{\"VisibilityTimeout\":\"70\",\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"$DLQ_ARN\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"}" --region "$REGION"
fi
SQS_URL=$(aws sqs get-queue-url --queue-name "$QUEUE_NAME" --region "$REGION" --query QueueUrl --output text)
SQS_ARN=$(aws sqs get-queue-attributes --queue-url "$SQS_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text --region "$REGION")

aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "ProcessorAccessPolicy" --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:GetQueueAttributes\"],\"Resource\":\"$SQS_ARN\"},{\"Effect\":\"Allow\",\"Action\":[\"dynamodb:PutItem\",\"dynamodb:GetItem\"],\"Resource\":\"$DYNAMO_ARN\"}]}"

# 3. Lambda Deployment
cd ../src/order_processor
zip -q ../../scripts/processor_lambda.zip index.py
cd ../../scripts

if ! aws lambda get-function --function-name "$LAMBDA_NAME" --region "$REGION" >/dev/null 2>&1; then
    for i in {1..3}; do
        aws lambda create-function --function-name "$LAMBDA_NAME" --runtime python3.12 --role "arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME" --handler index.lambda_handler --zip-file fileb://processor_lambda.zip --region "$REGION" --timeout 60 && break || sleep 10
    done
    aws lambda wait function-active-v2 --function-name "$LAMBDA_NAME" --region "$REGION"
else
    aws lambda update-function-code --function-name "$LAMBDA_NAME" --zip-file fileb://processor_lambda.zip --region "$REGION"
    aws lambda wait function-updated-v2 --function-name "$LAMBDA_NAME" --region "$REGION"
fi

aws lambda update-function-configuration --function-name "$LAMBDA_NAME" --region "$REGION" --environment "Variables={DYNAMODB_TABLE=$TABLE_NAME}"
aws lambda wait function-updated-v2 --function-name "$LAMBDA_NAME" --region "$REGION"

MAPPING_UUID=$(aws lambda list-event-source-mappings --function-name "$LAMBDA_NAME" --region "$REGION" --query "EventSourceMappings[?EventSourceArn=='$SQS_ARN'].UUID" --output text)
if [ -z "$MAPPING_UUID" ] || [ "$MAPPING_UUID" == "None" ]; then
    aws lambda create-event-source-mapping --function-name "$LAMBDA_NAME" --event-source-arn "$SQS_ARN" --batch-size 1 --region "$REGION"
fi

# 4. EventBridge Rule
aws events put-rule --name "$RULE_NAME" --event-bus-name "$BUS_NAME" --event-pattern "{\"source\": [\"lab.aula1.pedidos.validacao\"], \"detail-type\": [\"NovoPedidoValidado\"]}" --region "$REGION"
aws events put-targets --rule "$RULE_NAME" --event-bus-name "$BUS_NAME" --targets "Id"="TargetSQS","Arn"="$SQS_ARN" --region "$REGION"
aws sqs set-queue-attributes --queue-url "$SQS_URL" --region "$REGION" --attributes "{\"Policy\":\"{\\\"Version\\\":\\\"2012-10-17\\\",\\\"Statement\\\":[{\\\"Effect\\\":\\\"Allow\\\",\\\"Principal\\\":{\\\"Service\\\":\\\"events.amazonaws.com\\\"},\\\"Action\\\":\\\"SQS:SendMessage\\\",\\\"Resource\\\":\\\"$SQS_ARN\\\",\\\"Condition\\\":{\\\"ArnLike\\\":{\\\"aws:SourceArn\\\":\\\"arn:aws:events:$REGION:$ACCOUNT_ID:rule/$BUS_NAME/$RULE_NAME\\\"}}}]}\"}"

rm processor_lambda.zip