#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

load_env "$SCRIPT_DIR/../.env"
validate_env "AWS_REGION" "RESOURCE_SUFFIX"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="$AWS_REGION"
SUFFIX="$RESOURCE_SUFFIX"
BUS_NAME="pedidos-event-bus-$SUFFIX"
PROD_TABLE="orders-production-db-$SUFFIX"

echo "--- Starting Full System Validation ---"

# 1. Teste de Ingestao (API)
API_ID=$(aws apigateway get-rest-apis --region "$REGION" --query "items[?name=='order-ingestion-api-$SUFFIX'].id" --output text)
ENDPOINT="https://$API_ID.execute-api.$REGION.amazonaws.com/prod/orders"

ORDER_ID="PRO-$(date +%s)"
echo "Sending order $ORDER_ID via API..."
curl -s -k -X POST "$ENDPOINT" -H "Content-Type: application/json" -d "{\"pedidoId\": \"$ORDER_ID\", \"clienteId\": \"USER-01\"}" > /dev/null

sleep 10

# 2. Teste de Alteracao
echo "Sending Update Event for $ORDER_ID..."
aws events put-events --region "$REGION" --entries "[{
    \"Source\": \"app.orders.operations\",
    \"DetailType\": \"AlterarPedido\",
    \"Detail\": \"{\\\"pedidoId\\\": \\\"$ORDER_ID\\\", \\\"novosItens\\\": [{\\\"sku\\\": \\\"VALIDATED-ITEM\\\", \\\"qtd\\\": 1}]}\",
    \"EventBusName\": \"$BUS_NAME\"
}]" > /dev/null

sleep 10

# 3. Teste de Cancelamento
echo "Sending Cancel Event for $ORDER_ID..."
aws events put-events --region "$REGION" --entries "[{
    \"Source\": \"app.orders.operations\",
    \"DetailType\": \"CancelarPedido\",
    \"Detail\": \"{\\\"pedidoId\\\": \\\"$ORDER_ID\\\"}\",
    \"EventBusName\": \"$BUS_NAME\"
}]" > /dev/null

echo "Waiting for async processing (15s)..."
sleep 15

echo "--- Final Results ---"
aws dynamodb get-item --table-name "$PROD_TABLE" --region "$REGION" --key "{\"orderId\": {\"S\": \"$ORDER_ID\"}}" --query "Item.{ID:orderId, Status:status, Items:items}" --output table