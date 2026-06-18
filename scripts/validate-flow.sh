#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

load_env "$SCRIPT_DIR/../.env"
validate_env "AWS_REGION" "RESOURCE_SUFFIX"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
EVENT_BUS_NAME="orders-event-bus-${RESOURCE_SUFFIX}"
PRODUCTION_TABLE="order-production-data-${RESOURCE_SUFFIX}"
INGESTION_API_NAME="order-ingestion-api-${RESOURCE_SUFFIX}"

# === Run deploy scripts ===
echo "INFO: Running deploy scripts..."
bash "$SCRIPT_DIR/deploy-api-flow.sh"
bash "$SCRIPT_DIR/deploy-s3-flow.sh"
bash "$SCRIPT_DIR/deploy-order-processor.sh"
bash "$SCRIPT_DIR/deploy-lifecycle-ops.sh"

echo ""
echo "============================================="
echo " INICIANDO VALIDACAO DO FLUXO COMPLETO"
echo "============================================="

# === 1. API → LambdaPre → SQS FIFO → LambdaVal → EventBridge → SQS → LambdaPend → DynamoDB ===
echo ""
echo "--- Test 1: POST /orders via API Gateway ---"

REST_API_ID=$(aws apigateway get-rest-apis --region "$AWS_REGION" \
  --query "items[?name=='$INGESTION_API_NAME'].id" --output text)
if [ -z "$REST_API_ID" ] || [ "$REST_API_ID" == "None" ]; then
    echo "FAIL: Could not find REST API named $INGESTION_API_NAME"
    exit 1
fi
ENDPOINT="https://${REST_API_ID}.execute-api.${AWS_REGION}.amazonaws.com/prod/orders"

ORDER_ID="ORD-$(date +%s)-$$"
RESPONSE=$(curl -s -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d "{\"pedidoId\":\"$ORDER_ID\",\"clienteId\":\"CLI-TEST1\",\"itens\":[{\"nome\":\"Item Teste\",\"quantidade\":2,\"preco\":25.0}]}" 2>&1 || echo "CURL_FAILED:$?")

if echo "$RESPONSE" | grep -q "Order accepted"; then
    echo "PASS: API returned success for order $ORDER_ID"
else
    echo "WARN: API call response: $RESPONSE"
    echo "      (may still propagate; continuing...)"
fi

echo "Waiting 20s for SQS FIFO + LambdaVal + EventBridge + SQS + LambdaPend processing..."
sleep 20

echo "--- Verifying DynamoDB production: order $ORDER_ID ---"
DDB_RESULT=$(aws dynamodb get-item --table-name "$PRODUCTION_TABLE" --key "{\"orderId\":{\"S\":\"$ORDER_ID\"}}" --region "$AWS_REGION" 2>&1)
if echo "$DDB_RESULT" | grep -q "PROCESSED"; then
    echo "PASS: Order $ORDER_ID found in DynamoDB with status PROCESSED"
else
    echo "FAIL: Order $ORDER_ID NOT found in DynamoDB (or wrong status)"
    echo "  DynamoDB response: $DDB_RESULT"
fi

# === 2. S3 → SQS → LambdaFileVal → DynamoDB Audit (NO EventBridge) ===
echo ""
echo "--- Test 2: S3 File Upload (Validation + Audit only) ---"

S3_BUCKET="order-files-bucket-${RESOURCE_SUFFIX}"
S3_FILE_BODY='{"lista_pedidos":[{"id_pedido_arquivo":"BAT-100","id_cliente_arquivo":"CLI-BATCH","itens_pedido_arquivo":[{"nome":"Item Lote","quantidade":1,"preco":99.9}]}]}'
S3_KEY="pedidos_$(date +%s).json"

echo "Uploading test file to s3://${S3_BUCKET}/${S3_KEY}"
if aws s3 cp - "s3://${S3_BUCKET}/${S3_KEY}" --region "$AWS_REGION" <<< "$S3_FILE_BODY" 2>&1; then
    echo "PASS: File uploaded successfully"
else
    echo "FAIL: Upload failed"
fi

echo "Waiting 20s for SQS + LambdaFileVal processing..."
sleep 20

echo "--- Checking S3 batch audit table (should have PROCESSED entry) ---"
AUDIT_TABLE="order-batch-audit-${RESOURCE_SUFFIX}"
AUDIT_RESULT=$(aws dynamodb query --table-name "$AUDIT_TABLE" --key-condition-expression "file_name = :f" --expression-attribute-values "{\":f\":{\"S\":\"$S3_KEY\"}}" --region "$AWS_REGION" 2>&1)
if echo "$AUDIT_RESULT" | grep -q "PROCESSED"; then
    echo "PASS: Batch audit record found with status PROCESSED"
else
    echo "FAIL: Batch audit record not found or not PROCESSED"
    echo "  Audit result: $AUDIT_RESULT"
fi

echo "--- Verifying batch orders were NOT created in production table ---"
BATCH_PROD_RESULT=$(aws dynamodb get-item --table-name "$PRODUCTION_TABLE" --key "{\"orderId\":{\"S\":\"BAT-100\"}}" --region "$AWS_REGION" 2>&1)
if echo "$BATCH_PROD_RESULT" | grep -q "PROCESSED"; then
    echo "FAIL: Batch order BAT-100 was found in production table (should be audit-only!)"
else
    echo "PASS: Batch order BAT-100 correctly NOT in production table (audit-only flow)"
fi

# === 3. EventBridge Lifecycle Ops (Cancel) ===
echo ""
echo "--- Test 3: Cancel Operation via EventBridge ---"
CANCEL_DETAIL="{\"pedidoId\":\"$ORDER_ID\"}"
CANCEL_DETAIL_ESCAPED=$(echo "$CANCEL_DETAIL" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))' | sed 's/^"//;s/"$//')
aws events put-events --region "$AWS_REGION" --entries "[{\"Source\":\"app.orders.operations\",\"DetailType\":\"OrderCancelled\",\"Detail\":\"$CANCEL_DETAIL_ESCAPED\",\"EventBusName\":\"$EVENT_BUS_NAME\"}]" >/dev/null 2>&1 && echo "PASS: Cancel event published" || echo "WARN: Could not publish cancel event"

echo "Waiting 15s for cancel processing..."
sleep 15

CANCEL_RESULT=$(aws dynamodb get-item --table-name "$PRODUCTION_TABLE" --key "{\"orderId\":{\"S\":\"$ORDER_ID\"}}" --region "$AWS_REGION" 2>&1)
if echo "$CANCEL_RESULT" | grep -q "CANCELLED"; then
    echo "PASS: Order $ORDER_ID cancelled successfully"
else
    echo "FAIL: Order $ORDER_ID was NOT cancelled"
    echo "  DynamoDB result: $CANCEL_RESULT"
fi

# === 4. EventBridge Lifecycle Ops (Update) ===
echo ""
echo "--- Test 4: Update Operation via EventBridge ---"
UPDATE_DETAIL="{\"pedidoId\":\"$ORDER_ID\",\"novosItens\":[{\"nome\":\"Item Atualizado\",\"quantidade\":5,\"preco\":150.0}]}"
UPDATE_DETAIL_ESCAPED=$(echo "$UPDATE_DETAIL" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))' | sed 's/^"//;s/"$//')
aws events put-events --region "$AWS_REGION" --entries "[{\"Source\":\"app.orders.operations\",\"DetailType\":\"OrderUpdated\",\"Detail\":\"$UPDATE_DETAIL_ESCAPED\",\"EventBusName\":\"$EVENT_BUS_NAME\"}]" >/dev/null 2>&1 && echo "PASS: Update event published" || echo "WARN: Could not publish update event"

echo "Waiting 15s for update processing..."
sleep 15

UPDATE_RESULT=$(aws dynamodb get-item --table-name "$PRODUCTION_TABLE" --key "{\"orderId\":{\"S\":\"$ORDER_ID\"}}" --region "$AWS_REGION" 2>&1)
if echo "$UPDATE_RESULT" | grep -q "UPDATED"; then
    echo "PASS: Order $ORDER_ID updated successfully"
else
    echo "FAIL: Order $ORDER_ID was NOT updated"
    echo "  DynamoDB result: $UPDATE_RESULT"
fi

# === Summary ===
echo ""
echo "============================================="
echo " VALIDACAO CONCLUIDA"
echo "============================================="
echo "Orders created via API:"
echo "  - $ORDER_ID"
echo ""
echo "Batch files processed (audit-only):"
echo "  - $S3_KEY (check DynamoDB table '$AUDIT_TABLE')"
echo ""
echo "Production table: $PRODUCTION_TABLE"
echo "S3 bucket: order-files-bucket-$RESOURCE_SUFFIX"
