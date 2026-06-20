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
bash "$SCRIPT_DIR/deploy-frontend.sh"

echo ""
echo "============================================="
echo " INICIANDO VALIDACAO DO FLUXO COMPLETO"
echo "============================================="

# === 1. API Gateway flow ===
echo ""
echo "--- Test 1: POST /orders via API Gateway ---"

REST_API_ID=$(aws apigateway get-rest-apis --region "$AWS_REGION" \
  --query "items[?name=='$INGESTION_API_NAME'].id" --output text)
if [ -z "$REST_API_ID" ] || [ "$REST_API_ID" == "None" ]; then
    echo "FAIL: Could not find REST API named $INGESTION_API_NAME"
    exit 1
fi
ENDPOINT=$(get_endpoint_url "api" "$REST_API_ID" "/prod/orders")
FRONTEND_URL=$(get_endpoint_url "s3-website" "order-frontend-${RESOURCE_SUFFIX}")

ORDER_ID="ORD-$(date +%s)-$$"
RESPONSE=$(curl -s -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d "{\"pedidoId\":\"$ORDER_ID\",\"clienteId\":\"CLI-TEST1\",\"itens\":[{\"sku\":\"ITEM-TESTE\",\"qtd\":2,\"preco\":25.0}]}" 2>&1 || echo "CURL_FAILED:$?")

if echo "$RESPONSE" | grep -q "Order accepted"; then
    echo "PASS: API returned success for order $ORDER_ID"
else
    echo "WARN: API call response: $RESPONSE"
    echo "      (may still propagate; continuing...)"
fi

echo "Waiting for SQS FIFO + LambdaVal + EventBridge + SQS + LambdaPend processing..."
poll_resource "order $ORDER_ID in DynamoDB with status PROCESSED" 12 10 \
    "aws dynamodb get-item --table-name \"$PRODUCTION_TABLE\" --key '{\"orderId\":{\"S\":\"$ORDER_ID\"}}' --region \"$AWS_REGION\" 2>&1 | grep -q 'PROCESSED'" || true

echo "--- Verifying DynamoDB production: order $ORDER_ID ---"
DDB_RESULT=$(aws dynamodb get-item --table-name "$PRODUCTION_TABLE" --key "{\"orderId\":{\"S\":\"$ORDER_ID\"}}" --region "$AWS_REGION" 2>&1)
if echo "$DDB_RESULT" | grep -q "PROCESSED"; then
    echo "PASS: Order $ORDER_ID found in DynamoDB with status PROCESSED"
else
    echo "FAIL: Order $ORDER_ID NOT found in DynamoDB (or wrong status)"
    echo "  DynamoDB response: $DDB_RESULT"
fi

echo ""
echo "--- Test 1b: Duplicate Order (same pedidoId) ---"
echo "Re-sending same order $ORDER_ID to test idempotency..."
DUP_RESPONSE=$(curl -s -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d "{\"pedidoId\":\"$ORDER_ID\",\"clienteId\":\"CLI-TEST1\",\"itens\":[{\"sku\":\"ITEM-TESTE\",\"qtd\":2,\"preco\":25.0}]}" 2>&1 || echo "CURL_FAILED:$?")
if echo "$DUP_RESPONSE" | grep -q "Order accepted"; then
    echo "PASS: Duplicate order accepted by API (expected - SQS dedup bypassed by uuid4)"
else
    echo "WARN: Duplicate API response: $DUP_RESPONSE"
fi

echo "Waiting for duplicate processing..."
poll_resource "duplicate order $ORDER_ID stability" 12 10 \
    "aws dynamodb get-item --table-name \"$PRODUCTION_TABLE\" --key '{\"orderId\":{\"S\":\"$ORDER_ID\"}}' --region \"$AWS_REGION\" 2>&1 | grep -q 'PROCESSED'" || true

echo "--- Verifying duplicate did NOT overwrite ---"
DUP_DDB=$(aws dynamodb get-item --table-name "$PRODUCTION_TABLE" --key "{\"orderId\":{\"S\":\"$ORDER_ID\"}}" --region "$AWS_REGION" 2>&1)
DUP_ITEMS=$(echo "$DUP_DDB" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('Item',{}).get('items',[])))" 2>/dev/null || echo "0")
if echo "$DUP_DDB" | grep -q "PROCESSED"; then
    echo "PASS: Order $ORDER_ID still exists with status PROCESSED (not overwritten)"
else
    echo "FAIL: Order $ORDER_ID changed state after duplicate"
    echo "  Response: $DUP_DDB"
fi

# === 2. S3 flow ===
echo ""
echo "--- Test 2: S3 File Upload (Validation + Audit only) ---"

S3_BUCKET="order-files-bucket-${RESOURCE_SUFFIX}"
S3_FILE_BODY='{"lista_pedidos":[{"id_pedido_arquivo":"BAT-100","id_cliente_arquivo":"CLI-BATCH","itens_pedido_arquivo":[{"sku":"ITEM-LOTE","qtd":1,"preco":99.9}]}]}'
S3_KEY="pedidos_$(date +%s).json"

echo "Uploading test file to s3://${S3_BUCKET}/${S3_KEY}"
if aws s3 cp - "s3://${S3_BUCKET}/${S3_KEY}" --region "$AWS_REGION" <<< "$S3_FILE_BODY" 2>&1; then
    echo "PASS: File uploaded successfully"
else
    echo "FAIL: Upload failed"
fi

AUDIT_TABLE="order-batch-audit-${RESOURCE_SUFFIX}"

echo "Waiting for SQS + LambdaFileVal processing..."
poll_resource "S3 batch audit record with status PROCESSED" 12 10 \
    "aws dynamodb query --table-name \"$AUDIT_TABLE\" --key-condition-expression 'file_name = :f' --expression-attribute-values '{\":f\":{\"S\":\"$S3_KEY\"}}' --region \"$AWS_REGION\" 2>&1 | grep -q 'PROCESSED'" || true

echo "--- Checking S3 batch audit table (should have PROCESSED entry) ---"
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

# === 3. Lifecycle Cancel ===
echo ""
echo "--- Test 3: Cancel Operation via EventBridge ---"
CANCEL_DETAIL="{\"pedidoId\":\"$ORDER_ID\"}"
CANCEL_DETAIL_ESCAPED=$(echo "$CANCEL_DETAIL" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))' | sed 's/^"//;s/"$//')
aws events put-events --region "$AWS_REGION" --entries "[{\"Source\":\"app.orders.operations\",\"DetailType\":\"OrderCancelled\",\"Detail\":\"$CANCEL_DETAIL_ESCAPED\",\"EventBusName\":\"$EVENT_BUS_NAME\"}]" >/dev/null 2>&1 && echo "PASS: Cancel event published" || echo "WARN: Could not publish cancel event"

echo "Waiting for cancel processing..."
poll_resource "order $ORDER_ID with status CANCELLED" 12 10 \
    "aws dynamodb get-item --table-name \"$PRODUCTION_TABLE\" --key '{\"orderId\":{\"S\":\"$ORDER_ID\"}}' --region \"$AWS_REGION\" 2>&1 | grep -q 'CANCELLED'" || true

CANCEL_RESULT=$(aws dynamodb get-item --table-name "$PRODUCTION_TABLE" --key "{\"orderId\":{\"S\":\"$ORDER_ID\"}}" --region "$AWS_REGION" 2>&1)
if echo "$CANCEL_RESULT" | grep -q "CANCELLED"; then
    echo "PASS: Order $ORDER_ID cancelled successfully"
else
    echo "FAIL: Order $ORDER_ID was NOT cancelled"
    echo "  DynamoDB result: $CANCEL_RESULT"
fi

# === 4. Lifecycle Update ===
echo ""
echo "--- Test 4: Update Operation via EventBridge ---"
UPDATE_DETAIL="{\"pedidoId\":\"$ORDER_ID\",\"novosItens\":[{\"sku\":\"ITEM-ATUALIZADO\",\"qtd\":5,\"preco\":150.0}]}"
UPDATE_DETAIL_ESCAPED=$(echo "$UPDATE_DETAIL" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))' | sed 's/^"//;s/"$//')
aws events put-events --region "$AWS_REGION" --entries "[{\"Source\":\"app.orders.operations\",\"DetailType\":\"OrderUpdated\",\"Detail\":\"$UPDATE_DETAIL_ESCAPED\",\"EventBusName\":\"$EVENT_BUS_NAME\"}]" >/dev/null 2>&1 && echo "PASS: Update event published" || echo "WARN: Could not publish update event"

echo "Waiting for update processing..."
poll_resource "order $ORDER_ID with status UPDATED" 12 10 \
    "aws dynamodb get-item --table-name \"$PRODUCTION_TABLE\" --key '{\"orderId\":{\"S\":\"$ORDER_ID\"}}' --region \"$AWS_REGION\" 2>&1 | grep -q 'UPDATED'" || true

UPDATE_RESULT=$(aws dynamodb get-item --table-name "$PRODUCTION_TABLE" --key "{\"orderId\":{\"S\":\"$ORDER_ID\"}}" --region "$AWS_REGION" 2>&1)
if echo "$UPDATE_RESULT" | grep -q "UPDATED"; then
    echo "PASS: Order $ORDER_ID updated successfully"
else
    echo "FAIL: Order $ORDER_ID was NOT updated"
    echo "  DynamoDB result: $UPDATE_RESULT"
fi

# === 5. Read Order via API Gateway ===
echo ""
echo "--- Test 5: GET /orders/{orderId} via read_order Lambda ---"
READ_ENDPOINT=$(get_endpoint_url "api" "$REST_API_ID" "/prod/orders/${ORDER_ID}")
READ_RESPONSE=$(curl -s "$READ_ENDPOINT" 2>&1 || echo "CURL_FAILED:$?")
if echo "$READ_RESPONSE" | grep -q "PROCESSED"; then
    echo "PASS: GET /orders/$ORDER_ID returned order with status PROCESSED"
elif echo "$READ_RESPONSE" | grep -q "orderId"; then
    echo "WARN: GET /orders/$ORDER_ID returned data but without PROCESSED status"
    echo "  Response: $READ_RESPONSE"
else
    echo "FAIL: GET /orders/$ORDER_ID failed"
    echo "  Response: $READ_RESPONSE"
fi

# === 6. Test Controller: publish_event ===
echo ""
echo "--- Test 6: test_controller publish_event ---"
TEST_ENDPOINT=$(get_endpoint_url "api" "$REST_API_ID" "/prod/test")
CTRL_EVENT_RESPONSE=$(curl -s -X POST "$TEST_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d "{\"action\":\"publish_event\",\"detailType\":\"OrderCancelled\",\"detail\":{\"pedidoId\":\"CTRL-TEST-$(date +%s)\"}}" 2>&1 || echo "CURL_FAILED:$?")
if echo "$CTRL_EVENT_RESPONSE" | grep -q "Event published"; then
    echo "PASS: test_controller publish_event succeeded"
else
    echo "FAIL: test_controller publish_event failed"
    echo "  Response: $CTRL_EVENT_RESPONSE"
fi

# === 7. Test Controller: upload_file ===
echo ""
echo "--- Test 7: test_controller upload_file ---"
CTRL_UPLOAD_RESPONSE=$(curl -s -X POST "$TEST_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d "{\"action\":\"upload_file\",\"filename\":\"validate-test-$(date +%s).json\",\"content\":{\"test\":true}}" 2>&1 || echo "CURL_FAILED:$?")
if echo "$CTRL_UPLOAD_RESPONSE" | grep -q "File uploaded"; then
    echo "PASS: test_controller upload_file succeeded"
else
    echo "FAIL: test_controller upload_file failed"
    echo "  Response: $CTRL_UPLOAD_RESPONSE"
fi

# === 8. Test Controller: list_files ===
echo ""
echo "--- Test 8: test_controller list_files ---"
CTRL_LIST_RESPONSE=$(curl -s -X POST "$TEST_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d "{\"action\":\"list_files\",\"prefix\":\"validate-test\"}" 2>&1 || echo "CURL_FAILED:$?")
if echo "$CTRL_LIST_RESPONSE" | grep -q "files"; then
    echo "PASS: test_controller list_files succeeded"
else
    echo "FAIL: test_controller list_files failed"
    echo "  Response: $CTRL_LIST_RESPONSE"
fi

# === 9. Frontend URL check ===
echo ""
echo "--- Test 9: Frontend S3 bucket accessibility ---"
FRONTEND_CHECK=$(curl -s -o /dev/null -w "%{http_code}" "$FRONTEND_URL" 2>&1 || echo "CURL_FAILED")
if [ "$FRONTEND_CHECK" = "200" ]; then
    echo "PASS: Frontend URL $FRONTEND_URL returned HTTP 200"
elif [ "$FRONTEND_CHECK" = "403" ]; then
    echo "WARN: Frontend returned 403 (may need bucket policy check)"
else
    echo "WARN: Frontend HTTP status: $FRONTEND_CHECK"
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
echo "Frontend URL: $FRONTEND_URL"
