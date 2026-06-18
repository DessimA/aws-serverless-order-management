#!/usr/bin/env bash
set -euo pipefail

if [ -f ../.env ]; then export $(grep -v '^#' ../.env | xargs); fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="$AWS_REGION"
SUFFIX="$RESOURCE_SUFFIX"

ROLE_NAME="order-lifecycle-role-$SUFFIX"
TABLE_NAME="orders-production-db-$SUFFIX"
BUS_NAME="pedidos-event-bus-$SUFFIX"

# 1. IAM Role com pausa
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
    aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    echo "Aguardando propagacao do IAM Role..."
    sleep 15
fi

OPS=("cancel" "update")
for OP in "${OPS[@]}"; do
    QUEUE="order-$OP-queue-$SUFFIX"
    DLQ="order-$OP-dlq-$SUFFIX"
    LAMBDA="order-$OP-processor-$SUFFIX"
    RULE="order-$OP-routing-rule-$SUFFIX"
    DETAIL_TYPE=$([ "$OP" == "cancel" ] && echo "CancelarPedido" || echo "AlterarPedido")

    # Queues
    aws sqs create-queue --queue-name "$DLQ" --region "$REGION" >/dev/null 2>&1 || true
    DLQ_ARN=$(aws sqs get-queue-attributes --queue-url "$(aws sqs get-queue-url --queue-name "$DLQ" --region "$REGION" --query QueueUrl --output text)" --attribute-names QueueArn --query Attributes.QueueArn --output text --region "$REGION")
    
    aws sqs create-queue --queue-name "$QUEUE" --attributes "{\"VisibilityTimeout\":\"70\",\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"$DLQ_ARN\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"}" --region "$REGION" >/dev/null 2>&1 || true
    SQS_URL=$(aws sqs get-queue-url --queue-name "$QUEUE" --region "$REGION" --query QueueUrl --output text)
    SQS_ARN=$(aws sqs get-queue-attributes --queue-url "$SQS_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text --region "$REGION")

    # Lambda Deployment
    cd ../src/lifecycle_ops
    zip -q "$OP.zip" "${OP}_order.py"
    if ! aws lambda get-function --function-name "$LAMBDA" --region "$REGION" >/dev/null 2>&1; then
        for i in {1..3}; do
            aws lambda create-function --function-name "$LAMBDA" --runtime python3.12 --role "arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME" --handler "${OP}_order.lambda_handler" --zip-file fileb://$OP.zip --region "$REGION" --timeout 60 && break || sleep 10
        done
        aws lambda wait function-active-v2 --function-name "$LAMBDA" --region "$REGION"
    else
        aws lambda update-function-code --function-name "$LAMBDA" --zip-file fileb://$OP.zip --region "$REGION" >/dev/null
        aws lambda wait function-updated-v2 --function-name "$LAMBDA" --region "$REGION"
    fi
    aws lambda update-function-configuration --function-name "$LAMBDA" --environment "Variables={DYNAMODB_TABLE=$TABLE_NAME}" --region "$REGION" >/dev/null
    aws lambda wait function-updated-v2 --function-name "$LAMBDA" --region "$REGION"
    rm "$OP.zip"
    cd ../../scripts

    # Trigger SQS
    MAPPING_UUID=$(aws lambda list-event-source-mappings --function-name "$LAMBDA" --region "$REGION" --query "EventSourceMappings[?EventSourceArn=='$SQS_ARN'].UUID" --output text)
    if [ -z "$MAPPING_UUID" ] || [ "$MAPPING_UUID" == "None" ]; then
        aws lambda create-event-source-mapping --function-name "$LAMBDA" --event-source-arn "$SQS_ARN" --batch-size 1 --region "$REGION"
    fi

    # EventBridge Rule
    aws events put-rule --name "$RULE" --event-bus-name "$BUS_NAME" --event-pattern "{\"source\": [\"lab.aula4.operacoes\"], \"detail-type\": [\"$DETAIL_TYPE\"]}" --region "$REGION"
    aws events put-targets --rule "$RULE" --event-bus-name "$BUS_NAME" --targets "Id"="T1","Arn"="$SQS_ARN" --region "$REGION"
    aws sqs set-queue-attributes --queue-url "$SQS_URL" --region "$REGION" --attributes "{\"Policy\":\"{\\\"Version\\\":\\\"2012-10-17\\\",\\\"Statement\\\":[{\\\"Effect\\\":\\\"Allow\\\",\\\"Principal\\\":{\\\"Service\\\":\\\"events.amazonaws.com\\\"},\\\"Action\\\":\\\"SQS:SendMessage\\\",\\\"Resource\\\":\\\"$SQS_ARN\\\",\\\"Condition\\\":{\\\"ArnEquals\\\":{\\\"aws:SourceArn\\\":\\\"arn:aws:events:$REGION:$ACCOUNT_ID:rule/$BUS_NAME/$RULE\\\"}}}]}\"}"
done

# Permissoes Finais
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "LifecycleAccessPolicy" --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:GetQueueAttributes\"],\"Resource\":\"arn:aws:sqs:$REGION:$ACCOUNT_ID:order-*-queue-$SUFFIX\"},{\"Effect\":\"Allow\",\"Action\":[\"dynamodb:UpdateItem\",\"dynamodb:GetItem\"],\"Resource\":\"arn:aws:dynamodb:$REGION:$ACCOUNT_ID:table/$TABLE_NAME\"}]}"