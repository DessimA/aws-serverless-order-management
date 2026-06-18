#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/lib.sh"

load_env "$SCRIPT_DIR/.env"
validate_env "RESOURCE_SUFFIX" "AWS_REGION"

SUFFIX=$RESOURCE_SUFFIX
REGION=$AWS_REGION
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "--------------------------------------------------------"
echo "RESUMO PARA LIMPEZA DE RECURSOS"
echo "--------------------------------------------------------"
echo "Identificador (Suffix): $SUFFIX"
echo "Regiao AWS:             $REGION"
echo "ID da Conta:            $ACCOUNT_ID"
echo "--------------------------------------------------------"
echo "AVISO: Apenas recursos contendo '$SUFFIX' no nome serao removidos."
echo "--------------------------------------------------------"
read -p "Os dados acima estao corretos? (y/n): " confirm

if [ "$confirm" != "y" ]; then
    echo "Operacao cancelada pelo usuario."
    exit 0
fi

echo "Iniciando limpeza..."

BUS_NAME="pedidos-event-bus-$SUFFIX"
if aws events describe-event-bus --name "$BUS_NAME" --region "$REGION" >/dev/null 2>&1; then
    RULES=$(aws events list-rules --event-bus-name "$BUS_NAME" --query "Rules[*].Name" --output text --region "$REGION")
    for rule in $RULES; do
        if [ "$rule" != "None" ] && [ -n "$rule" ]; then
            TARGETS=$(aws events list-targets-by-rule --rule "$rule" --event-bus-name "$BUS_NAME" --query "Targets[*].Id" --output text --region "$REGION")
            if [ "$TARGETS" != "None" ] && [ -n "$TARGETS" ]; then
                # shellcheck disable=SC2086
                aws events remove-targets --rule "$rule" --event-bus-name "$BUS_NAME" --ids $TARGETS --region "$REGION"
            fi
            aws events delete-rule --name "$rule" --event-bus-name "$BUS_NAME" --region "$REGION"
        fi
    done
    aws events delete-event-bus --name "$BUS_NAME" --region "$REGION"
fi
sleep 2

API_IDS=$(aws apigateway get-rest-apis --query "items[?contains(name, '$SUFFIX')].id" --output text --region "$REGION")
for id in $API_IDS; do
    if [ "$id" != "None" ] && [ -n "$id" ]; then
        aws apigateway delete-rest-api --rest-api-id "$id" --region "$REGION"
    fi
done
sleep 2

FUNCTIONS=$(aws lambda list-functions --query "Functions[?contains(FunctionName, '$SUFFIX')].FunctionName" --output text --region "$REGION")
for func in $FUNCTIONS; do
    if [ "$func" != "None" ] && [ -n "$func" ]; then
        MAPS=$(aws lambda list-event-source-mappings --function-name "$func" --query "EventSourceMappings[*].UUID" --output text --region "$REGION")
        for uuid in $MAPS; do
            if [ "$uuid" != "None" ] && [ -n "$uuid" ]; then
                aws lambda delete-event-source-mapping --uuid "$uuid" --region "$REGION"
            fi
        done
        aws lambda delete-function --function-name "$func" --region "$REGION"
    fi
done
sleep 2

QUEUES=$(aws sqs list-queues --region "$REGION" --query "QueueUrls[?contains(@, '$SUFFIX')]" --output text)
for q in $QUEUES; do
    if [ "$q" != "None" ] && [ -n "$q" ]; then
        aws sqs delete-queue --queue-url "$q" --region "$REGION"
    fi
done
sleep 2

TABLES=$(aws dynamodb list-tables --region "$REGION" --query "TableNames[?contains(@, '$SUFFIX')]" --output text)
for table in $TABLES; do
    if [ "$table" != "None" ] && [ -n "$table" ]; then
        aws dynamodb delete-table --table-name "$table" --region "$REGION"
    fi
done
sleep 2

BUCKETS=("datalake-arquivos-$SUFFIX" "order-drop-zone-$SUFFIX")
for bucket in "${BUCKETS[@]}"; do
    if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
        aws s3 rm "s3://$bucket" --recursive --region "$REGION"
        aws s3 rb "s3://$bucket" --force --region "$REGION"
    fi
done
sleep 2

TOPICS=$(aws sns list-topics --region "$REGION" --query "Topics[?contains(TopicArn, '$SUFFIX')].TopicArn" --output text)
for topic in $TOPICS; do
    if [ "$topic" != "None" ] && [ -n "$topic" ]; then
        aws sns delete-topic --topic-arn "$topic" --region "$REGION"
    fi
done
sleep 2

ROLES=$(aws iam list-roles --query "Roles[?contains(RoleName, '$SUFFIX')].RoleName" --output text)
for role in $ROLES; do
    if [ "$role" != "None" ] && [ -n "$role" ]; then
        POLS=$(aws iam list-attached-role-policies --role-name "$role" --query "AttachedPolicies[*].PolicyArn" --output text)
        for p in $POLS; do
            if [ "$p" != "None" ] && [ -n "$p" ]; then
                aws iam detach-role-policy --role-name "$role" --policy-arn "$p"
            fi
        done
        INLINE=$(aws iam list-role-policies --role-name "$role" --query "PolicyNames[*]" --output text)
        for i in $INLINE; do
            if [ "$i" != "None" ] && [ -n "$i" ]; then
                aws iam delete-role-policy --role-name "$role" --policy-name "$i"
            fi
        done
        aws iam delete-role --role-name "$role"
    fi
done

echo "--------------------------------------------------------"
echo "VALIDANDO EXCLUSAO"
echo "--------------------------------------------------------"
CHECK_LAMBDA=$(aws lambda list-functions --query "Functions[?contains(FunctionName, '$SUFFIX')].FunctionName" --output text --region "$REGION")
if [ -z "$CHECK_LAMBDA" ]; then echo "Lambdas: OK"; else echo "PENDENTE: $CHECK_LAMBDA"; fi

CHECK_SQS=$(aws sqs list-queues --region "$REGION" --query "QueueUrls[?contains(@, '$SUFFIX')]" --output text)
if [ -z "$CHECK_SQS" ] || [ "$CHECK_SQS" == "None" ]; then echo "SQS: OK"; else echo "PENDENTE: $CHECK_SQS"; fi

echo "--------------------------------------------------------"
echo "Limpeza finalizada."
echo "--------------------------------------------------------"