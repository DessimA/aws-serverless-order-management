#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source "$SCRIPT_DIR/lib.sh"

load_env "$SCRIPT_DIR/../.env"
validate_env "AWS_REGION" "RESOURCE_SUFFIX"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
EVENT_BUS_NAME="orders-event-bus-${RESOURCE_SUFFIX}"
PRODUCTION_TABLE="order-production-data-${RESOURCE_SUFFIX}"
INGESTION_API_NAME="order-ingestion-api-${RESOURCE_SUFFIX}"

# === Run deploy via Terraform ===
echo "INFO: Provisionando infraestrutura com Terraform..."
bash "$SCRIPT_DIR/generate-tfvars.sh"
cd "$SCRIPT_DIR/.."
docker compose run --rm terraform init -upgrade
docker compose run --rm terraform apply -auto-approve
cd "$SCRIPT_DIR"
chown "$(id -u):$(id -g)" "$SCRIPT_DIR/.jwt-secret" "$SCRIPT_DIR/.api-key" 2>/dev/null || true
bash "$SCRIPT_DIR/seed-catalog.sh"

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
S3_FILE_BODY='{"lista_pedidos":[{"pedidoId":"BAT-100","clienteId":"CLI-BATCH","itens":[{"sku":"ITEM-LOTE","qtd":1,"preco":99.9}]}]}'
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

# === 4. Lifecycle Update (fresh order, not cancelled) ===
echo ""
echo "--- Test 4: Update Operation via EventBridge (fresh order) ---"
UPDATE_ORDER_ID="ORD-$(date +%s)-$$-UPD"
echo "Creating fresh order $UPDATE_ORDER_ID for update test..."
curl -s -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d "{\"pedidoId\":\"$UPDATE_ORDER_ID\",\"clienteId\":\"CLI-TEST1\",\"itens\":[{\"sku\":\"ITEM-TESTE\",\"qtd\":2,\"preco\":25.0}]}" >/dev/null 2>&1
poll_resource "order $UPDATE_ORDER_ID with status PROCESSED" 12 10 \
    "aws dynamodb get-item --table-name \"$PRODUCTION_TABLE\" --key '{\"orderId\":{\"S\":\"$UPDATE_ORDER_ID\"}}' --region \"$AWS_REGION\" 2>&1 | grep -q 'PROCESSED'" || true

UPDATE_DETAIL="{\"pedidoId\":\"$UPDATE_ORDER_ID\",\"novosItens\":[{\"sku\":\"ITEM-ATUALIZADO\",\"qtd\":5,\"preco\":150.0}]}"
UPDATE_DETAIL_ESCAPED=$(echo "$UPDATE_DETAIL" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))' | sed 's/^"//;s/"$//')
aws events put-events --region "$AWS_REGION" --entries "[{\"Source\":\"app.orders.operations\",\"DetailType\":\"OrderUpdated\",\"Detail\":\"$UPDATE_DETAIL_ESCAPED\",\"EventBusName\":\"$EVENT_BUS_NAME\"}]" >/dev/null 2>&1 && echo "PASS: Update event published" || echo "WARN: Could not publish update event"

echo "Waiting for update processing..."
poll_resource "order $UPDATE_ORDER_ID with status UPDATED" 12 10 \
    "aws dynamodb get-item --table-name \"$PRODUCTION_TABLE\" --key '{\"orderId\":{\"S\":\"$UPDATE_ORDER_ID\"}}' --region \"$AWS_REGION\" 2>&1 | grep -q 'UPDATED'" || true

UPDATE_RESULT=$(aws dynamodb get-item --table-name "$PRODUCTION_TABLE" --key "{\"orderId\":{\"S\":\"$UPDATE_ORDER_ID\"}}" --region "$AWS_REGION" 2>&1)
if echo "$UPDATE_RESULT" | grep -q "UPDATED"; then
    echo "PASS: Order $UPDATE_ORDER_ID updated successfully"
else
    echo "FAIL: Order $UPDATE_ORDER_ID was NOT updated"
    echo "  DynamoDB result: $UPDATE_RESULT"
fi

# === 4b. Cancel then attempt update (must remain CANCELLED) ===
echo ""
echo "--- Test 4b: Cancel then Update (CANCELLED must be terminal) ---"
CANCEL_DETAIL_4b="{\"pedidoId\":\"$ORDER_ID\"}"
CANCEL_DETAIL_4b_ESC=$(echo "$CANCEL_DETAIL_4b" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))' | sed 's/^"//;s/"$//')
aws events put-events --region "$AWS_REGION" --entries "[{\"Source\":\"app.orders.operations\",\"DetailType\":\"OrderCancelled\",\"Detail\":\"$CANCEL_DETAIL_4b_ESC\",\"EventBusName\":\"$EVENT_BUS_NAME\"}]" >/dev/null 2>&1 && echo "PASS: Cancel event published for 4b" || echo "WARN: Could not publish cancel event"

poll_resource "order $ORDER_ID with status CANCELLED" 12 10 \
    "aws dynamodb get-item --table-name \"$PRODUCTION_TABLE\" --key '{\"orderId\":{\"S\":\"$ORDER_ID\"}}' --region \"$AWS_REGION\" 2>&1 | grep -q 'CANCELLED'" || true

UPDATE_DETAIL_4b="{\"pedidoId\":\"$ORDER_ID\",\"novosItens\":[{\"sku\":\"SHOULD-NOT-APPEAR\",\"qtd\":999,\"preco\":1.0}]}"
UPDATE_DETAIL_4b_ESC=$(echo "$UPDATE_DETAIL_4b" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))' | sed 's/^"//;s/"$//')
aws events put-events --region "$AWS_REGION" --entries "[{\"Source\":\"app.orders.operations\",\"DetailType\":\"OrderUpdated\",\"Detail\":\"$UPDATE_DETAIL_4b_ESC\",\"EventBusName\":\"$EVENT_BUS_NAME\"}]" >/dev/null 2>&1 && echo "PASS: Update event published for 4b" || echo "WARN: Could not publish update event"

sleep 5

CANCEL_UPDATE_CHECK=$(aws dynamodb get-item --table-name "$PRODUCTION_TABLE" --key "{\"orderId\":{\"S\":\"$ORDER_ID\"}}" --region "$AWS_REGION" 2>&1)
if echo "$CANCEL_UPDATE_CHECK" | grep -q "CANCELLED"; then
    echo "PASS: Order $ORDER_ID remains CANCELLED after update attempt (terminal state enforced)"
else
    echo "FAIL: Order $ORDER_ID status changed after cancelled update attempt"
    echo "  DynamoDB result: $CANCEL_UPDATE_CHECK"
fi

# === 5. Read Order via API Gateway requires auth ===
echo ""
echo "--- Test 5: GET /orders/{orderId} requires auth (401 sem token) ---"
READ_ORDER_ID="${UPDATE_ORDER_ID:-$ORDER_ID}"
READ_ENDPOINT=$(get_endpoint_url "api" "$REST_API_ID" "/prod/orders/${READ_ORDER_ID}")
READ_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$READ_ENDPOINT" 2>&1 || echo "CURL_FAILED")
if [ "$READ_HTTP_CODE" = "401" ]; then
    echo "PASS: GET /orders/$READ_ORDER_ID returned 401 (auth required by gateway)"
else
    echo "FAIL: GET /orders/$READ_ORDER_ID returned HTTP $READ_HTTP_CODE (expected 401)"
fi

# === Load API Key for /test ===
API_KEY_FILE="$SCRIPT_DIR/.api-key"
API_KEY_VALUE=""
if [ -f "$API_KEY_FILE" ]; then
    API_KEY_VALUE=$(cat "$API_KEY_FILE")
fi

# === Test 6a: POST /test without API Key must return 403 ===
echo ""
echo "--- Test 6a: POST /test without API Key must return 403 ---"
TEST_ENDPOINT=$(get_endpoint_url "api" "$REST_API_ID" "/prod/test")
CTRL_NO_KEY_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$TEST_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d "{\"action\":\"publish_event\",\"detailType\":\"OrderCancelled\",\"detail\":{\"pedidoId\":\"CTRL-NO-KEY-$(date +%s)\"}}" 2>&1 || echo "CURL_FAILED")
if [ "$CTRL_NO_KEY_RESPONSE" = "403" ]; then
    echo "PASS: POST /test without API Key returned 403 Forbidden"
else
    echo "FAIL: POST /test without API Key returned HTTP $CTRL_NO_KEY_RESPONSE (expected 403)"
fi

# === 6. Test Controller: publish_event ===
echo ""
echo "--- Test 6: test_controller publish_event ---"
CTRL_EVENT_RESPONSE=$(curl -s -X POST "$TEST_ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $API_KEY_VALUE" \
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
  -H "x-api-key: $API_KEY_VALUE" \
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
  -H "x-api-key: $API_KEY_VALUE" \
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

# === 10. CloudWatch Log Retention Verification ===
echo ""
echo "--- Test 10: CloudWatch Log Retention (14 days) ---"
for CHECK_LAMBDA in "order-persister-$RESOURCE_SUFFIX" "order-pre-validator-$RESOURCE_SUFFIX"; do
    RETENTION=$(aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/$CHECK_LAMBDA" --region "$AWS_REGION" --query "logGroups[0].retentionInDays" --output text 2>/dev/null || echo "NOT_FOUND")
    if [ "$RETENTION" = "14" ]; then
        echo "PASS: Log group /aws/lambda/$CHECK_LAMBDA has retentionInDays=14"
    else
        echo "FAIL: Log group /aws/lambda/$CHECK_LAMBDA retention=$RETENTION (expected 14)"
    fi
done

# === 11. CloudWatch DLQ Alarms Verification ===
echo ""
echo "--- Test 11: DLQ Alarms exist ---"
for ALARM_NAME in "dlq-alarm-validation-$RESOURCE_SUFFIX" "dlq-alarm-persister-$RESOURCE_SUFFIX" "dlq-alarm-cancel-$RESOURCE_SUFFIX" "dlq-alarm-update-$RESOURCE_SUFFIX" "dlq-alarm-s3-batch-$RESOURCE_SUFFIX"; do
    ALARM_EXISTS=$(aws cloudwatch describe-alarms --alarm-names "$ALARM_NAME" --region "$AWS_REGION" --query "MetricAlarms[0].AlarmName" --output text 2>/dev/null || echo "NOT_FOUND")
    if [ "$ALARM_EXISTS" != "None" ] && [ "$ALARM_EXISTS" != "NOT_FOUND" ]; then
        echo "PASS: Alarm $ALARM_NAME exists"
    else
        echo "FAIL: Alarm $ALARM_NAME not found"
    fi
done

# === 12. Reserved Concurrency Verification ===
echo ""
echo "--- Test 12: Reserved Concurrency ---"
for CHECK_LAMBDA in "order-persister-$RESOURCE_SUFFIX" "order-gateway-$RESOURCE_SUFFIX"; do
    RC_VALUE=$(aws lambda get-function-concurrency --function-name "$CHECK_LAMBDA" --region "$AWS_REGION" --query "ReservedConcurrentExecutions" --output text 2>/dev/null || echo "NOT_FOUND")
    if [ "$CHECK_LAMBDA" = "order-gateway-$RESOURCE_SUFFIX" ]; then
        EXPECTED_RC="10"
    else
        EXPECTED_RC="5"
    fi
    if [ "$RC_VALUE" = "$EXPECTED_RC" ]; then
        echo "PASS: $CHECK_LAMBDA has ReservedConcurrentExecutions=$EXPECTED_RC"
    else
        echo "FAIL: $CHECK_LAMBDA ReservedConcurrentExecutions=$RC_VALUE (expected $EXPECTED_RC)"
    fi
done

# === 13. DynamoDB Audit Table TTL Verification ===
echo ""
echo "--- Test 13: DynamoDB Audit Table TTL ---"
AUDIT_TABLE_NAME="order-batch-audit-$RESOURCE_SUFFIX"
TTL_STATUS=$(aws dynamodb describe-time-to-live --table-name "$AUDIT_TABLE_NAME" --region "$AWS_REGION" --query "TimeToLiveDescription.TimeToLiveStatus" --output text 2>/dev/null || echo "NOT_FOUND")
if [ "$TTL_STATUS" = "ENABLED" ]; then
    echo "PASS: Audit table $AUDIT_TABLE_NAME has TimeToLiveStatus=ENABLED"
else
    echo "FAIL: Audit table TTL status=$TTL_STATUS (expected ENABLED)"
fi

# === 14. Test Controller detailType Allowlist ===
echo ""
echo "--- Test 14: test_controller reject invalid detailType ---"
CTRL_INVALID_DT_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$TEST_ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $API_KEY_VALUE" \
  -d "{\"action\":\"publish_event\",\"detailType\":\"OrderCreated\",\"detail\":{\"pedidoId\":\"CTRL-BAD-DT-$(date +%s)\"}}" 2>&1 || echo "CURL_FAILED")
if [ "$CTRL_INVALID_DT_HTTP" = "400" ]; then
    echo "PASS: test_controller rejeitou detailType invalido com HTTP 400"
else
    echo "FAIL: test_controller retornou HTTP $CTRL_INVALID_DT_HTTP (esperado 400)"
fi

# === 15. Resource Policy Structural Validation ===
echo ""
echo "--- Test 15: Resource Policy structural validation ---"

ALLOWED_IP="${ALLOWED_SOURCE_IP:-}"
if [ -z "$ALLOWED_IP" ]; then
    echo "SKIP: ALLOWED_SOURCE_IP vazio, sem Resource Policy para validar."
else
    POLICY_JSON=$(aws apigateway get-rest-api --rest-api-id "$REST_API_ID" --region "$AWS_REGION" --query policy --output text 2>/dev/null || echo "NONE")
    if [ -z "$POLICY_JSON" ] || [ "$POLICY_JSON" == "NONE" ] || [ "$POLICY_JSON" == "None" ]; then
        echo "FAIL: Nenhuma Resource Policy encontrada na API $REST_API_ID"
        exit 1
    fi
    echo "Resource Policy encontrada. Validando estrutura..."
    ALLOW_COUNT=$(echo "$POLICY_JSON" | python3 -c "
import sys, json
policy = json.loads(sys.stdin.read())
count = 0
for stmt in policy.get('Statement', []):
    if stmt.get('Effect') == 'Allow' and '/*' in stmt.get('Resource', '') and '/POST/test' not in stmt.get('Resource', ''):
        count += 1
print(count)
" 2>/dev/null || echo "0")
    if [ "$ALLOW_COUNT" -lt 1 ]; then
        echo "FAIL: Nenhuma declaracao Allow com Resource terminando em /*"
        echo "  Policy: $POLICY_JSON"
        exit 1
    fi
    echo "PASS: Encontrada $ALLOW_COUNT declaracao(oes) Allow com Resource terminando em /*"
    DENY_COUNT=$(echo "$POLICY_JSON" | python3 -c "
import sys, json
policy = json.loads(sys.stdin.read())
count = 0
for stmt in policy.get('Statement', []):
    if stmt.get('Effect') == 'Deny' and '/POST/test' in stmt.get('Resource', '') and 'NotIpAddress' in json.dumps(stmt.get('Condition', {})):
        count += 1
print(count)
" 2>/dev/null || echo "0")
    if [ "$DENY_COUNT" -lt 1 ]; then
        echo "FAIL: Nenhuma declaracao Deny com Resource /POST/test e Condition NotIpAddress"
        echo "  Policy: $POLICY_JSON"
        exit 1
    fi
    echo "PASS: Encontrada $DENY_COUNT declaracao(oes) Deny com Resource /POST/test e Condition NotIpAddress"
fi

# === 16. Customer Auth: Register, Login, Me ===
echo ""
echo "--- Test 16: Customer Register, Login and Me ---"

CUSTOMER_EMAIL="teste-$(date +%s)-$$@example.com"
CUSTOMER_PASSWORD="SenhaForte123!"

REGISTER_ENDPOINT=$(get_endpoint_url "api" "$REST_API_ID" "/prod/customers/register")
LOGIN_ENDPOINT=$(get_endpoint_url "api" "$REST_API_ID" "/prod/customers/login")
ME_ENDPOINT=$(get_endpoint_url "api" "$REST_API_ID" "/prod/customers/me")

REG_RESPONSE=$(curl -s -X POST "$REGISTER_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$CUSTOMER_EMAIL\",\"password\":\"$CUSTOMER_PASSWORD\"}" 2>&1 || echo "CURL_FAILED:$?")
REG_CLIENTE_ID=$(echo "$REG_RESPONSE" | python3 -c "import sys,json;print(json.load(sys.stdin).get('clienteId',''))" 2>/dev/null || echo "")
if [ -n "$REG_CLIENTE_ID" ]; then
    echo "PASS: Register returned clienteId $REG_CLIENTE_ID"
else
    echo "FAIL: Register did not return clienteId"
    echo "  Response: $REG_RESPONSE"
fi

LOGIN_RESPONSE=$(curl -s -X POST "$LOGIN_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$CUSTOMER_EMAIL\",\"password\":\"$CUSTOMER_PASSWORD\"}" 2>&1 || echo "CURL_FAILED:$?")
LOGIN_TOKEN=$(echo "$LOGIN_RESPONSE" | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")
LOGIN_CLIENTE_ID=$(echo "$LOGIN_RESPONSE" | python3 -c "import sys,json;print(json.load(sys.stdin).get('clienteId',''))" 2>/dev/null || echo "")
if [ -n "$LOGIN_TOKEN" ] && [ "$LOGIN_CLIENTE_ID" = "$REG_CLIENTE_ID" ]; then
    echo "PASS: Login returned token and matching clienteId"
else
    echo "FAIL: Login failed or clienteId mismatch"
    echo "  Response: $LOGIN_RESPONSE"
fi

ME_RESPONSE=$(curl -s "$ME_ENDPOINT" \
  -H "Authorization: Bearer $LOGIN_TOKEN" 2>&1 || echo "CURL_FAILED:$?")
ME_CLIENTE_ID=$(echo "$ME_RESPONSE" | python3 -c "import sys,json;print(json.load(sys.stdin).get('clienteId',''))" 2>/dev/null || echo "")
ME_EMAIL=$(echo "$ME_RESPONSE" | python3 -c "import sys,json;print(json.load(sys.stdin).get('email',''))" 2>/dev/null || echo "")
if [ "$ME_CLIENTE_ID" = "$REG_CLIENTE_ID" ] && [ "$ME_EMAIL" = "$CUSTOMER_EMAIL" ]; then
    echo "PASS: Me returned matching clienteId and email"
else
    echo "FAIL: Me response mismatch"
    echo "  Response: $ME_RESPONSE"
fi

echo ""
echo "--- Test 17: Duplicate register returns 409 ---"
DUP_REG_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$REGISTER_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$CUSTOMER_EMAIL\",\"password\":\"$CUSTOMER_PASSWORD\"}" 2>&1 || echo "CURL_FAILED")
if [ "$DUP_REG_RESPONSE" = "409" ]; then
    echo "PASS: Duplicate register returned 409"
else
    echo "FAIL: Duplicate register returned HTTP $DUP_REG_RESPONSE (expected 409)"
fi

echo ""
echo "--- Test 18: Login with wrong password returns 401 ---"
WRONG_LOGIN_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$LOGIN_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$CUSTOMER_EMAIL\",\"password\":\"SenhaErrada123\"}" 2>&1 || echo "CURL_FAILED")
if [ "$WRONG_LOGIN_RESPONSE" = "401" ]; then
    echo "PASS: Login with wrong password returned 401"
else
    echo "FAIL: Login with wrong password returned HTTP $WRONG_LOGIN_RESPONSE (expected 401)"
fi

# === 19. Catalog Reader: GET /catalog returns available items ===
echo ""
echo "--- Test 19: GET /catalog retorna cursos disponiveis ---"

CATALOG_ENDPOINT=$(get_endpoint_url "api" "$REST_API_ID" "/prod/catalog")
CATALOG_LIST_RESPONSE=$(curl -s "$CATALOG_ENDPOINT" 2>&1 || echo "CURL_FAILED:$?")

CHECK_HAS_ITEMS=$(echo "$CATALOG_LIST_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if 'items' in data and data.get('count', 0) > 0:
    print('OK')
else:
    print('FAIL')
" 2>/dev/null || echo "FAIL")

CHECK_NO_GCP_PCA=$(echo "$CATALOG_LIST_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
found = any(item.get('cursoId') == 'GCP-PCA-001' for item in data.get('items', []))
print('FAIL' if found else 'OK')
" 2>/dev/null || echo "FAIL")

if [ "$CHECK_HAS_ITEMS" = "OK" ] && [ "$CHECK_NO_GCP_PCA" = "OK" ]; then
    echo "PASS: Catalog list returned items and GCP-PCA-001 (disponivel=false) is absent"
else
    echo "FAIL: Catalog list check failed (has_items=$CHECK_HAS_ITEMS, no_gcp_pca=$CHECK_NO_GCP_PCA)"
    echo "  Response: $CATALOG_LIST_RESPONSE"
fi

# === 20. Catalog Reader: GET /catalog/{cursoId} ===
echo ""
echo "--- Test 20: GET /catalog/{cursoId} retorna curso ou 404 ---"

CATALOG_ITEM_RESPONSE=$(curl -s "$CATALOG_ENDPOINT/AWS-CP-001" 2>&1 || echo "CURL_FAILED:$?")
CHECK_ITEM_FOUND=$(echo "$CATALOG_ITEM_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print('OK' if data.get('cursoId') == 'AWS-CP-001' else 'FAIL')
" 2>/dev/null || echo "FAIL")

UNAVAILABLE_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$CATALOG_ENDPOINT/GCP-PCA-001" 2>&1 || echo "CURL_FAILED")

if [ "$CHECK_ITEM_FOUND" = "OK" ] && [ "$UNAVAILABLE_HTTP_CODE" = "404" ]; then
    echo "PASS: GET /catalog/AWS-CP-001 returned item, GET /catalog/GCP-PCA-001 returned 404"
else
    echo "FAIL: Catalog item check failed (item_found=$CHECK_ITEM_FOUND, unavailable_http=$UNAVAILABLE_HTTP_CODE)"
fi

# === 21. Order Gateway: GET /orders lists only own orders ===
echo ""
echo "--- Test 21: GET /orders lista pedidos do cliente autenticado ---"

if [ -z "${LOGIN_TOKEN:-}" ] || [ -z "${LOGIN_CLIENTE_ID:-}" ]; then
    echo "SKIP: LOGIN_TOKEN ou LOGIN_CLIENTE_ID vazios (Teste 16 pode ter falhado)"
else
    GW_ENDPOINT=$(get_endpoint_url "api" "$REST_API_ID" "/prod/orders")
    GW_ORDER_ID="ORD-GW-$(date +%s)-$$"
    curl -s -X POST "$ENDPOINT" \
      -H "Content-Type: application/json" \
      -d "{\"pedidoId\":\"$GW_ORDER_ID\",\"clienteId\":\"$LOGIN_CLIENTE_ID\",\"itens\":[{\"sku\":\"AWS-CP-001\",\"qtd\":1,\"preco\":149.90}]}" >/dev/null 2>&1

    poll_resource "order $GW_ORDER_ID with status PROCESSED" 12 10 \
        "aws dynamodb get-item --table-name \"$PRODUCTION_TABLE\" --key '{\"orderId\":{\"S\":\"$GW_ORDER_ID\"}}' --region \"$AWS_REGION\" 2>&1 | grep -q 'PROCESSED'" || true

    LIST_RESPONSE=$(curl -s "$GW_ENDPOINT" \
      -H "Authorization: Bearer $LOGIN_TOKEN" 2>&1 || echo "CURL_FAILED:$?")

    LIST_COUNT=$(echo "$LIST_RESPONSE" | python3 -c "import sys,json;print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")
    LIST_HAS_ORDER=$(echo "$LIST_RESPONSE" | python3 -c "
import sys,json
orders=json.load(sys.stdin).get('orders',[])
ids=[o.get('orderId') for o in orders]
exit(0) if '$GW_ORDER_ID' in ids else exit(1)
" 2>/dev/null && echo "OK" || echo "NO")

    if [ "$LIST_COUNT" -gt 0 ] && [ "$LIST_HAS_ORDER" = "OK" ]; then
        echo "PASS: GET /orders returned count=$LIST_COUNT with order $GW_ORDER_ID present"
    else
        echo "FAIL: GET /orders check failed (count=$LIST_COUNT, has_order=$LIST_HAS_ORDER)"
        echo "  Response: $LIST_RESPONSE"
    fi
fi

# === 22. Order Gateway: GET /orders/{orderId} validates owner ===
echo ""
echo "--- Test 22: GET /orders/{orderId} valida dono do pedido ---"

if [ -z "${LOGIN_TOKEN:-}" ] || [ -z "${LOGIN_CLIENTE_ID:-}" ]; then
    echo "SKIP: LOGIN_TOKEN ou LOGIN_CLIENTE_ID vazios"
else
    OWN_ORDER_RESPONSE=$(curl -s "$GW_ENDPOINT/$GW_ORDER_ID" \
      -H "Authorization: Bearer $LOGIN_TOKEN" 2>&1 || echo "CURL_FAILED:$?")
    OWN_ORDER_OK=$(echo "$OWN_ORDER_RESPONSE" | python3 -c "
import sys,json
data=json.load(sys.stdin)
print('OK') if data.get('orderId') == '$GW_ORDER_ID' else print('FAIL')
" 2>/dev/null || echo "FAIL")

    OTHER_ORDER_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" "$GW_ENDPOINT/$ORDER_ID" \
      -H "Authorization: Bearer $LOGIN_TOKEN" 2>&1 || echo "CURL_FAILED")

    if [ "$OWN_ORDER_OK" = "OK" ] && [ "$OTHER_ORDER_RESPONSE" = "404" ]; then
        echo "PASS: Own order returned 200, other client order returned 404"
    else
        echo "FAIL: Owner check failed (own=$OWN_ORDER_OK, other_http=$OTHER_ORDER_RESPONSE)"
    fi
fi

# === 23. Order Gateway: POST /orders/{orderId}/cancel (autenticado) ===
echo ""
echo "--- Test 23: POST /orders/{orderId}/cancel autenticado ---"

if [ -z "${LOGIN_TOKEN:-}" ]; then
    echo "SKIP: LOGIN_TOKEN vazio"
else
    TMPFILE=$(mktemp)
    CANCEL_HTTP=$(curl -s -w "%{http_code}" -X POST "$GW_ENDPOINT/$GW_ORDER_ID/cancel" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $LOGIN_TOKEN" \
      -d "{}" -o "$TMPFILE" 2>&1 || echo "CURL_FAILED")
    CANCEL_BODY=$(cat "$TMPFILE")
    rm -f "$TMPFILE"

    if [ "$CANCEL_HTTP" = "202" ] && echo "$CANCEL_BODY" | grep -q "Cancellation requested"; then
        echo "PASS: Cancel returned 202 with status 'Cancellation requested'"
    else
        echo "FAIL: Cancel response unexpected (http=$CANCEL_HTTP, body=$CANCEL_BODY)"
    fi

    poll_resource "order $GW_ORDER_ID with status CANCELLED" 12 10 \
        "aws dynamodb get-item --table-name \"$PRODUCTION_TABLE\" --key '{\"orderId\":{\"S\":\"$GW_ORDER_ID\"}}' --region \"$AWS_REGION\" 2>&1 | grep -q 'CANCELLED'" || true

    FINAL_STATUS=$(aws dynamodb get-item --table-name "$PRODUCTION_TABLE" --key "{\"orderId\":{\"S\":\"$GW_ORDER_ID\"}}" --region "$AWS_REGION" --query "Item.status.S" --output text 2>/dev/null || echo "NOT_FOUND")
    if [ "$FINAL_STATUS" = "CANCELLED" ]; then
        echo "PASS: Order $GW_ORDER_ID final status is CANCELLED"
    else
        echo "FAIL: Order $GW_ORDER_ID final status is $FINAL_STATUS (expected CANCELLED)"
    fi
fi

# === 24. Order Gateway: PATCH /orders/{orderId} (autenticado) ===
echo ""
echo "--- Test 24: PATCH /orders/{orderId} autenticado ---"

if [ -z "${LOGIN_TOKEN:-}" ]; then
    echo "SKIP: LOGIN_TOKEN vazio"
else
    GW_UPDATE_ORDER_ID="ORD-GW-UPD-$(date +%s)-$$"
    curl -s -X POST "$ENDPOINT" \
      -H "Content-Type: application/json" \
      -d "{\"pedidoId\":\"$GW_UPDATE_ORDER_ID\",\"clienteId\":\"$LOGIN_CLIENTE_ID\",\"itens\":[{\"sku\":\"AWS-CP-001\",\"qtd\":1,\"preco\":149.90}]}" >/dev/null 2>&1

    poll_resource "order $GW_UPDATE_ORDER_ID with status PROCESSED" 12 10 \
        "aws dynamodb get-item --table-name \"$PRODUCTION_TABLE\" --key '{\"orderId\":{\"S\":\"$GW_UPDATE_ORDER_ID\"}}' --region \"$AWS_REGION\" 2>&1 | grep -q 'PROCESSED'" || true

    TMPFILE=$(mktemp)
    UPDATE_HTTP=$(curl -s -w "%{http_code}" -X PATCH "$GW_ENDPOINT/$GW_UPDATE_ORDER_ID" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $LOGIN_TOKEN" \
      -d '{"novosItens":[{"sku":"AWS-SAA-001","qtd":1,"preco":249.90}]}' -o "$TMPFILE" 2>&1 || echo "CURL_FAILED")
    UPDATE_BODY=$(cat "$TMPFILE")
    rm -f "$TMPFILE"

    if [ "$UPDATE_HTTP" = "202" ] && echo "$UPDATE_BODY" | grep -q "Update requested"; then
        echo "PASS: Update returned 202 with status 'Update requested'"
    else
        echo "FAIL: Update response unexpected (http=$UPDATE_HTTP, body=$UPDATE_BODY)"
    fi

    poll_resource "order $GW_UPDATE_ORDER_ID with status UPDATED" 12 10 \
        "aws dynamodb get-item --table-name \"$PRODUCTION_TABLE\" --key '{\"orderId\":{\"S\":\"$GW_UPDATE_ORDER_ID\"}}' --region \"$AWS_REGION\" 2>&1 | grep -q 'UPDATED'" || true

    UPD_FINAL_STATUS=$(aws dynamodb get-item --table-name "$PRODUCTION_TABLE" --key "{\"orderId\":{\"S\":\"$GW_UPDATE_ORDER_ID\"}}" --region "$AWS_REGION" --query "Item.status.S" --output text 2>/dev/null || echo "NOT_FOUND")
    if [ "$UPD_FINAL_STATUS" = "UPDATED" ]; then
        echo "PASS: Order $GW_UPDATE_ORDER_ID final status is UPDATED"
    else
        echo "FAIL: Order $GW_UPDATE_ORDER_ID final status is $UPD_FINAL_STATUS (expected UPDATED)"
    fi
fi

# === 25. Frontend e QA Dashboard acessiveis ===
echo ""
echo "--- Test 25: Frontend e QA Dashboard acessiveis ---"

FRONTEND_QA_URL="${FRONTEND_URL}/qa.html"
QA_CHECK=$(curl -s -o /dev/null -w "%{http_code}" "$FRONTEND_QA_URL" 2>&1 || echo "CURL_FAILED")
if [ "$QA_CHECK" = "200" ]; then
    echo "PASS: QA Dashboard $FRONTEND_QA_URL retornou HTTP 200"
else
    echo "WARN: QA Dashboard HTTP status: $QA_CHECK"
fi

INDEX_CHECK=$(curl -s -o /dev/null -w "%{http_code}" "$FRONTEND_URL" 2>&1 || echo "CURL_FAILED")
if [ "$INDEX_CHECK" = "200" ]; then
    echo "PASS: Frontend principal $FRONTEND_URL retornou HTTP 200"
else
    echo "WARN: Frontend principal HTTP status: $INDEX_CHECK"
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
echo "Frontend URL:    $FRONTEND_URL"
echo "QA Dashboard:    ${FRONTEND_URL}/qa.html"
