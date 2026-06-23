#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source "$SCRIPT_DIR/lib.sh"

load_env "$SCRIPT_DIR/../.env"
validate_env "AWS_REGION" "RESOURCE_SUFFIX"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

ROLE_NAME="order-gateway-role-${RESOURCE_SUFFIX}"
LAMBDA_NAME="order-gateway-${RESOURCE_SUFFIX}"
TABLE_NAME="order-production-data-${RESOURCE_SUFFIX}"
EVENT_BUS_NAME="orders-event-bus-${RESOURCE_SUFFIX}"
REST_API_NAME="order-ingestion-api-${RESOURCE_SUFFIX}"
JWT_SECRET_FILE="$SCRIPT_DIR/.jwt-secret"

echo "============================================="
echo " DEPLOY ORDER GATEWAY"
echo "============================================="

# === Dependency checks ===
if ! aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "ERRO: Tabela $TABLE_NAME nao encontrada. Execute deploy-order-processor.sh primeiro."
    exit 1
fi

if ! aws events describe-event-bus --name "$EVENT_BUS_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "ERRO: EventBus $EVENT_BUS_NAME nao encontrado. Execute deploy-api-flow.sh primeiro."
    exit 1
fi

if [ ! -f "$JWT_SECRET_FILE" ]; then
    echo "ERRO: $JWT_SECRET_FILE nao encontrado. Execute deploy-customer-auth.sh primeiro."
    exit 1
fi
JWT_SECRET_VALUE=$(cat "$JWT_SECRET_FILE")

REST_API_ID=$(aws apigateway get-rest-apis --region "$AWS_REGION" \
    --query "items[?name=='$REST_API_NAME'].id" --output text)
if [ -z "$REST_API_ID" ] || [ "$REST_API_ID" == "None" ]; then
    echo "ERRO: REST API $REST_API_NAME nao encontrada. Execute deploy-api-flow.sh primeiro."
    exit 1
fi
validate_not_empty "REST_API_ID" "$REST_API_ID" "REST API ID"

TABLE_ARN=$(aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$AWS_REGION" --query Table.TableArn --output text)
EVENT_BUS_ARN=$(aws events describe-event-bus --name "$EVENT_BUS_NAME" --region "$AWS_REGION" --query Arn --output text)

echo "All dependencies validated."

# === GSI: clientId-index ===
GSI_COUNT=$(aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$AWS_REGION" \
    --query "length(Table.GlobalSecondaryIndexes[?IndexName=='clientId-index'])" --output text 2>/dev/null || echo "0")

if [ "$GSI_COUNT" = "0" ]; then
    echo "Creating GSI clientId-index on $TABLE_NAME..."
    aws dynamodb update-table --table-name "$TABLE_NAME" \
        --attribute-definitions AttributeName=clientId,AttributeType=S AttributeName=processedAt,AttributeType=S \
        --global-secondary-index-updates '[{
            "Create": {
                "IndexName": "clientId-index",
                "KeySchema": [
                    {"AttributeName":"clientId","KeyType":"HASH"},
                    {"AttributeName":"processedAt","KeyType":"RANGE"}
                ],
                "Projection": {"ProjectionType":"ALL"}
            }
        }]' --region "$AWS_REGION" >/dev/null

    poll_resource "GSI clientId-index to become ACTIVE" 30 10 \
        "aws dynamodb describe-table --table-name \"$TABLE_NAME\" --region \"$AWS_REGION\" \
        --query \"Table.GlobalSecondaryIndexes[?IndexName=='clientId-index'].IndexStatus\" \
        --output text 2>/dev/null | grep -q 'ACTIVE'"
    echo "GSI clientId-index is ACTIVE."
else
    echo "GSI clientId-index ja existe."
fi

INDEX_ARN="arn:aws:dynamodb:$AWS_REGION:$ACCOUNT_ID:table/$TABLE_NAME/index/clientId-index"

# === IAM Role ===
ensure_iam_lambda_role "$ROLE_NAME"

aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "OrderGatewayAccess" --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[
        {\"Effect\":\"Allow\",\"Action\":[\"dynamodb:GetItem\",\"dynamodb:Query\"],\"Resource\":[\"$TABLE_ARN\",\"$INDEX_ARN\"]},
        {\"Effect\":\"Allow\",\"Action\":\"events:PutEvents\",\"Resource\":\"$EVENT_BUS_ARN\"}
    ]
}"

# === Lambda Deployment ===
PKG_DIR=$(mktemp -d)
cp ../src/order_gateway/index.py "$PKG_DIR/"
mkdir -p "$PKG_DIR/common"
cp ../src/common/*.py "$PKG_DIR/common/"
cd "$PKG_DIR"
zip -qr "$SCRIPT_DIR/lambda_deploy_gateway.zip" .
cd "$SCRIPT_DIR"
rm -rf "$PKG_DIR"

ensure_lambda_function "$LAMBDA_NAME" "$ROLE_NAME" "index.lambda_handler" "lambda_deploy_gateway.zip" "$AWS_REGION" "$ACCOUNT_ID" "10" "DYNAMODB_TABLE=$TABLE_NAME,JWT_SECRET=$JWT_SECRET_VALUE,EVENT_BUS_NAME=$EVENT_BUS_NAME"

# === API Gateway Resources ===
ROOT_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$REST_API_ID" --region "$AWS_REGION" \
    --query "items[?path=='/'].id" --output text)

ORDERS_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$REST_API_ID" --region "$AWS_REGION" \
    --query "items[?path=='/orders'].id" --output text)
validate_not_empty "ORDERS_RESOURCE_ID" "$ORDERS_RESOURCE_ID" "/orders resource ID"

# Create /orders/{orderId} if it does not exist yet (deploy-frontend may not have run)
ORDER_ID_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$REST_API_ID" --region "$AWS_REGION" \
    --query "items[?path=='/orders/{orderId}'].id" --output text)
if [ -z "$ORDER_ID_RESOURCE_ID" ] || [ "$ORDER_ID_RESOURCE_ID" == "None" ]; then
    ORDER_ID_RESOURCE_ID=$(aws apigateway create-resource --rest-api-id "$REST_API_ID" \
        --parent-id "$ORDERS_RESOURCE_ID" --path-part "{orderId}" --region "$AWS_REGION" --query id --output text)
    echo "Created resource /orders/{orderId}"
fi
validate_not_empty "ORDER_ID_RESOURCE_ID" "$ORDER_ID_RESOURCE_ID" "/orders/{orderId} resource ID"

# Resource: /orders/{orderId}/cancel
CANCEL_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$REST_API_ID" --region "$AWS_REGION" \
    --query "items[?path=='/orders/{orderId}/cancel'].id" --output text)
if [ -z "$CANCEL_RESOURCE_ID" ] || [ "$CANCEL_RESOURCE_ID" == "None" ]; then
    CANCEL_RESOURCE_ID=$(aws apigateway create-resource --rest-api-id "$REST_API_ID" \
        --parent-id "$ORDER_ID_RESOURCE_ID" --path-part "cancel" --region "$AWS_REGION" --query id --output text)
    echo "Created resource /orders/{orderId}/cancel"
fi
validate_not_empty "CANCEL_RESOURCE_ID" "$CANCEL_RESOURCE_ID" "/orders/{orderId}/cancel resource ID"

FUNCTION_ARN="arn:aws:lambda:$AWS_REGION:$ACCOUNT_ID:function:$LAMBDA_NAME"

deploy_gateway_endpoint() {
    local resource_id="$1"
    local http_method="$2"
    local statement_id="$3"
    local api_path="$4"
    local request_params="${5:-}"

    if ! aws apigateway get-method --rest-api-id "$REST_API_ID" --resource-id "$resource_id" --http-method "$http_method" --region "$AWS_REGION" >/dev/null 2>&1; then
        if [ -n "$request_params" ]; then
            aws apigateway put-method --rest-api-id "$REST_API_ID" --resource-id "$resource_id" \
                --http-method "$http_method" --authorization-type "NONE" \
                --request-parameters "$request_params" --region "$AWS_REGION"
        else
            aws apigateway put-method --rest-api-id "$REST_API_ID" --resource-id "$resource_id" \
                --http-method "$http_method" --authorization-type "NONE" --region "$AWS_REGION"
        fi
    fi

    aws apigateway put-integration --rest-api-id "$REST_API_ID" --resource-id "$resource_id" \
        --http-method "$http_method" --type AWS_PROXY --integration-http-method POST \
        --uri "arn:aws:apigateway:$AWS_REGION:lambda:path/2015-03-31/functions/$FUNCTION_ARN/invocations" \
        --region "$AWS_REGION" >/dev/null 2>&1 || true

    setup_api_cors "$REST_API_ID" "$resource_id" "$AWS_REGION"

    aws lambda remove-permission --function-name "$LAMBDA_NAME" --statement-id "$statement_id" \
        --region "$AWS_REGION" 2>/dev/null || true
    aws lambda add-permission --function-name "$LAMBDA_NAME" --statement-id "$statement_id" \
        --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
        --source-arn "arn:aws:execute-api:$AWS_REGION:$ACCOUNT_ID:$REST_API_ID/*/$http_method/$api_path" \
        --region "$AWS_REGION"
}

# GET /orders (list for authenticated user)
deploy_gateway_endpoint "$ORDERS_RESOURCE_ID" "GET" "apigateway-gw-list" "orders"

# GET /orders/{orderId} (replaces read_order)
deploy_gateway_endpoint "$ORDER_ID_RESOURCE_ID" "GET" "apigateway-gw-get" "orders/{orderId}" "method.request.path.orderId=true"

# Remove old read_order permission
aws lambda remove-permission --function-name "order-reader-${RESOURCE_SUFFIX}" \
    --statement-id apigateway-reader --region "$AWS_REGION" 2>/dev/null || true

# PATCH /orders/{orderId}
deploy_gateway_endpoint "$ORDER_ID_RESOURCE_ID" "PATCH" "apigateway-gw-patch" "orders/{orderId}" "method.request.path.orderId=true"

# POST /orders/{orderId}/cancel
deploy_gateway_endpoint "$CANCEL_RESOURCE_ID" "POST" "apigateway-gw-cancel" "orders/{orderId}/cancel"

# Deploy API changes
aws apigateway create-deployment --rest-api-id "$REST_API_ID" --stage-name prod --region "$AWS_REGION" >/dev/null
echo "API Gateway deployment updated with order gateway endpoints."

LIST_ENDPOINT=$(get_endpoint_url "api" "$REST_API_ID" "/prod/orders")
GET_ENDPOINT=$(get_endpoint_url "api" "$REST_API_ID" "/prod/orders/{orderId}")
PATCH_ENDPOINT=$(get_endpoint_url "api" "$REST_API_ID" "/prod/orders/{orderId}")
CANCEL_ENDPOINT=$(get_endpoint_url "api" "$REST_API_ID" "/prod/orders/{orderId}/cancel")

rm -f lambda_deploy_gateway.zip

echo ""
echo "============================================="
echo " ORDER GATEWAY DEPLOY COMPLETE"
echo "============================================="
echo "List orders:   $LIST_ENDPOINT"
echo "Get order:     $GET_ENDPOINT"
echo "Update order:  $PATCH_ENDPOINT"
echo "Cancel order:  $CANCEL_ENDPOINT"
