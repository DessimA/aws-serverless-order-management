#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source "$SCRIPT_DIR/lib.sh"

load_env "$SCRIPT_DIR/../.env"
validate_env "AWS_REGION" "RESOURCE_SUFFIX"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REST_API_NAME="order-ingestion-api-$RESOURCE_SUFFIX"
EVENT_BUS_NAME="orders-event-bus-$RESOURCE_SUFFIX"
S3_BUCKET="order-files-bucket-$RESOURCE_SUFFIX"
FRONTEND_BUCKET="order-frontend-$RESOURCE_SUFFIX"

CTRL_ROLE_NAME="test-controller-role-$RESOURCE_SUFFIX"
CTRL_LAMBDA_NAME="test-controller-$RESOURCE_SUFFIX"

echo "============================================="
echo " DEPLOY FRONTEND + TEST/READ APIS"
echo "============================================="

if ! aws events describe-event-bus --name "$EVENT_BUS_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "ERRO: EventBus $EVENT_BUS_NAME not found. Deploy api-flow first."
    exit 1
fi
EVENT_BUS_ARN=$(aws events describe-event-bus --name "$EVENT_BUS_NAME" --region "$AWS_REGION" --query Arn --output text)
validate_not_empty "EVENT_BUS_ARN" "$EVENT_BUS_ARN" "EventBus ARN"

if ! aws s3api head-bucket --bucket "$FRONTEND_BUCKET" --region "$AWS_REGION" 2>/dev/null; then
    aws s3api create-bucket --bucket "$FRONTEND_BUCKET" --region "$AWS_REGION" \
        --create-bucket-configuration LocationConstraint="$AWS_REGION"
    echo "Frontend bucket created: $FRONTEND_BUCKET"
fi

aws s3api put-bucket-website --bucket "$FRONTEND_BUCKET" --website-configuration '{
    "IndexDocument": {"Suffix": "index.html"},
    "ErrorDocument": {"Key": "index.html"}
}' --region "$AWS_REGION"

aws s3api put-public-access-block --bucket "$FRONTEND_BUCKET" \
    --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" \
    --region "$AWS_REGION"

aws s3api put-bucket-policy --bucket "$FRONTEND_BUCKET" --policy "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
        \"Effect\": \"Allow\",
        \"Principal\": \"*\",
        \"Action\": \"s3:GetObject\",
        \"Resource\": \"arn:aws:s3:::$FRONTEND_BUCKET/*\"
    }]
}" --region "$AWS_REGION"

# ================================================================
# IAM ROLES
# ================================================================

ensure_iam_lambda_role "$CTRL_ROLE_NAME"
aws iam put-role-policy --role-name "$CTRL_ROLE_NAME" --policy-name "ControllerAccess" --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[
        {\"Effect\":\"Allow\",\"Action\":\"events:PutEvents\",\"Resource\":\"$EVENT_BUS_ARN\"},
        {\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:ListBucket\"],\"Resource\":[\"arn:aws:s3:::$S3_BUCKET\",\"arn:aws:s3:::$S3_BUCKET/*\"]}
    ]
}"

# ================================================================
# DEPLOY LAMBDAS
# ================================================================

deploy_lambda() {
    local lambda_name="$1"
    local role_name="$2"
    local src_dir="$3"
    local handler="$4"
    local zip_name="$5"

    PKG_DIR=$(mktemp -d)
    cp "$src_dir/index.py" "$PKG_DIR/"
    mkdir -p "$PKG_DIR/common"
    cp "$SCRIPT_DIR/../src/common/"*.py "$PKG_DIR/common/"
    cd "$PKG_DIR"
    zip -qr "$SCRIPT_DIR/$zip_name" .
    cd "$SCRIPT_DIR"
    rm -rf "$PKG_DIR"

    if ! aws lambda get-function --function-name "$lambda_name" --region "$AWS_REGION" >/dev/null 2>&1; then
        echo "Criando Lambda $lambda_name..."
        for i in {1..3}; do
            aws lambda create-function --function-name "$lambda_name" --runtime python3.12 \
                --role "arn:aws:iam::$ACCOUNT_ID:role/$role_name" \
                --handler "$handler" --zip-file "fileb://$zip_name" --timeout 60 --region "$AWS_REGION" && break || sleep 10
        done
        aws lambda wait function-active-v2 --function-name "$lambda_name" --region "$AWS_REGION"
    else
        aws lambda update-function-code --function-name "$lambda_name" --zip-file "fileb://$zip_name" --region "$AWS_REGION"
        aws lambda wait function-updated-v2 --function-name "$lambda_name" --region "$AWS_REGION"
    fi

    aws logs create-log-group --log-group-name "/aws/lambda/$lambda_name" --region "$AWS_REGION" 2>/dev/null || true
    aws logs put-retention-policy --log-group-name "/aws/lambda/$lambda_name" --retention-in-days 14 --region "$AWS_REGION" 2>/dev/null || true

    rm -f "$zip_name"
}

deploy_lambda "$CTRL_LAMBDA_NAME" "$CTRL_ROLE_NAME" "../src/test_controller" "index.lambda_handler" "lambda_deploy_ctrl.zip"
aws lambda update-function-configuration --function-name "$CTRL_LAMBDA_NAME" \
    --timeout 60 --environment "Variables={EVENT_BUS_NAME=$EVENT_BUS_NAME,S3_BUCKET=$S3_BUCKET}" --region "$AWS_REGION"
aws lambda put-function-concurrency --function-name "$CTRL_LAMBDA_NAME" --reserved-concurrent-executions 5 --region "$AWS_REGION"
validate_lambda_config "$CTRL_LAMBDA_NAME" "$AWS_REGION" "EVENT_BUS_NAME" "S3_BUCKET"

# ================================================================
# API GATEWAY - ADD NEW RESOURCES
# ================================================================

REST_API_ID=$(aws apigateway get-rest-apis --region "$AWS_REGION" \
    --query "items[?name=='$REST_API_NAME'].id" --output text)
validate_not_empty "REST_API_ID" "$REST_API_ID" "REST API ID"

if [ -z "$REST_API_ID" ] || [ "$REST_API_ID" == "None" ]; then
    echo "ERRO: REST API $REST_API_NAME not found. Deploy api-flow first."
    exit 1
fi

ROOT_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$REST_API_ID" --region "$AWS_REGION" \
    --query "items[?path=='/'].id" --output text)

ORDERS_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$REST_API_ID" --region "$AWS_REGION" \
    --query "items[?path=='/orders'].id" --output text)

if [ -z "$ORDERS_RESOURCE_ID" ] || [ "$ORDERS_RESOURCE_ID" == "None" ]; then
    echo "ERRO: /orders resource not found. Deploy api-flow first."
    exit 1
fi

# --- Resource: /orders/{orderId} ---
ORDER_ID_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$REST_API_ID" --region "$AWS_REGION" \
    --query "items[?path=='/orders/{orderId}'].id" --output text)

if [ -z "$ORDER_ID_RESOURCE_ID" ] || [ "$ORDER_ID_RESOURCE_ID" == "None" ]; then
    ORDER_ID_RESOURCE_ID=$(aws apigateway create-resource --rest-api-id "$REST_API_ID" \
        --parent-id "$ORDERS_RESOURCE_ID" --path-part "{orderId}" --region "$AWS_REGION" --query id --output text)
    echo "Created resource /orders/{orderId}"
fi
validate_not_empty "ORDER_ID_RESOURCE_ID" "$ORDER_ID_RESOURCE_ID" "/orders/{orderId} resource ID"

# --- Resource: /test ---
TEST_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$REST_API_ID" --region "$AWS_REGION" \
    --query "items[?path=='/test'].id" --output text)

if [ -z "$TEST_RESOURCE_ID" ] || [ "$TEST_RESOURCE_ID" == "None" ]; then
    TEST_RESOURCE_ID=$(aws apigateway create-resource --rest-api-id "$REST_API_ID" \
        --parent-id "$ROOT_RESOURCE_ID" --path-part "test" --region "$AWS_REGION" --query id --output text)
    echo "Created resource /test"
fi
validate_not_empty "TEST_RESOURCE_ID" "$TEST_RESOURCE_ID" "/test resource ID"

# POST /test → test_controller (com API Key obrigatoria)
if ! aws apigateway get-method --rest-api-id "$REST_API_ID" --resource-id "$TEST_RESOURCE_ID" --http-method POST --region "$AWS_REGION" >/dev/null 2>&1; then
    aws apigateway put-method --rest-api-id "$REST_API_ID" --resource-id "$TEST_RESOURCE_ID" \
        --http-method POST --authorization-type "NONE" --api-key-required --region "$AWS_REGION"
fi

aws apigateway get-integration --rest-api-id "$REST_API_ID" --resource-id "$TEST_RESOURCE_ID" --http-method POST --region "$AWS_REGION" >/dev/null 2>&1 || \
aws apigateway put-integration --rest-api-id "$REST_API_ID" --resource-id "$TEST_RESOURCE_ID" \
    --http-method POST --type AWS_PROXY --integration-http-method POST \
    --uri "arn:aws:apigateway:$AWS_REGION:lambda:path/2015-03-31/functions/arn:aws:lambda:$AWS_REGION:$ACCOUNT_ID:function:$CTRL_LAMBDA_NAME/invocations" \
    --region "$AWS_REGION"

setup_api_cors "$REST_API_ID" "$TEST_RESOURCE_ID" "$AWS_REGION"

# Lambda permission for API Gateway → test_controller
aws lambda remove-permission --function-name "$CTRL_LAMBDA_NAME" --statement-id apigateway-ctrl \
    --region "$AWS_REGION" 2>/dev/null || true
aws lambda add-permission --function-name "$CTRL_LAMBDA_NAME" --statement-id apigateway-ctrl \
    --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:$AWS_REGION:$ACCOUNT_ID:$REST_API_ID/*/POST/test" \
    --region "$AWS_REGION"

# === Resource Policy (restrito a POST /test) ===
ensure_api_resource_policy "$REST_API_ID" "$AWS_REGION"

# === Usage Plan + API Key para /test ===
ensure_usage_plan_with_api_key "$REST_API_ID" "$AWS_REGION"

# Deploy API changes
aws apigateway create-deployment --rest-api-id "$REST_API_ID" --stage-name prod --region "$AWS_REGION" >/dev/null
echo "API Gateway deployment updated."

# ================================================================
# BUILD AND UPLOAD FRONTEND
# ================================================================

API_ENDPOINT=$(get_endpoint_url "api" "$REST_API_ID" "/prod/orders")
TEST_ENDPOINT=$(get_endpoint_url "api" "$REST_API_ID" "/prod/test")
READ_ENDPOINT=$(get_endpoint_url "api" "$REST_API_ID" "/prod/orders/{orderId}")
CATALOG_ENDPOINT=$(get_endpoint_url "api" "$REST_API_ID" "/prod/catalog")
ORDERS_ENDPOINT=$(get_endpoint_url "api" "$REST_API_ID" "/prod/orders")
CUSTOMERS_ENDPOINT=$(get_endpoint_url "api" "$REST_API_ID" "/prod/customers")

BUILD_DIR=$(mktemp -d)
cp "$SCRIPT_DIR/../frontend/index.html" "$BUILD_DIR/"
cp "$SCRIPT_DIR/../frontend/qa.html" "$BUILD_DIR/"
cp "$SCRIPT_DIR/../frontend/style.css" "$BUILD_DIR/"
cp "$SCRIPT_DIR/../frontend/app.js" "$BUILD_DIR/"
cp "$SCRIPT_DIR/../frontend/qa.js" "$BUILD_DIR/"
cp "$SCRIPT_DIR/../frontend/config.template.js" "$BUILD_DIR/config.js"

# Inject environment values
API_KEY_VALUE=$(cat "$SCRIPT_DIR/.api-key" 2>/dev/null || echo "")

sed -i "s|__API_ENDPOINT__|$API_ENDPOINT|g" "$BUILD_DIR/config.js"
sed -i "s|__TEST_ENDPOINT__|$TEST_ENDPOINT|g" "$BUILD_DIR/config.js"
sed -i "s|__READ_ENDPOINT__|$READ_ENDPOINT|g" "$BUILD_DIR/config.js"
sed -i "s|__S3_BUCKET__|$S3_BUCKET|g" "$BUILD_DIR/config.js"
sed -i "s|__AWS_REGION__|$AWS_REGION|g" "$BUILD_DIR/config.js"
sed -i "s|__TEST_API_KEY__|$API_KEY_VALUE|g" "$BUILD_DIR/config.js"
sed -i "s|__CATALOG_ENDPOINT__|$CATALOG_ENDPOINT|g" "$BUILD_DIR/config.js"
sed -i "s|__ORDERS_ENDPOINT__|$ORDERS_ENDPOINT|g" "$BUILD_DIR/config.js"
sed -i "s|__CUSTOMERS_ENDPOINT__|$CUSTOMERS_ENDPOINT|g" "$BUILD_DIR/config.js"

# Sync to S3
aws s3 sync "$BUILD_DIR/" "s3://${FRONTEND_BUCKET}/" --region "$AWS_REGION" --delete
aws s3api head-object --bucket "$FRONTEND_BUCKET" --key "index.html" --region "$AWS_REGION" >/dev/null 2>&1 || { echo "FALHA: index.html not found in frontend bucket after sync" >&2; exit 1; }
aws s3api head-object --bucket "$FRONTEND_BUCKET" --key "qa.html" --region "$AWS_REGION" >/dev/null 2>&1 || { echo "FALHA: qa.html not found in frontend bucket after sync" >&2; exit 1; }
aws s3api head-object --bucket "$FRONTEND_BUCKET" --key "qa.js" --region "$AWS_REGION" >/dev/null 2>&1 || { echo "FALHA: qa.js not found in frontend bucket after sync" >&2; exit 1; }
aws s3api head-object --bucket "$FRONTEND_BUCKET" --key "config.js" --region "$AWS_REGION" >/dev/null 2>&1 || { echo "FALHA: config.js not found in frontend bucket after sync" >&2; exit 1; }
rm -rf "$BUILD_DIR"



FRONTEND_URL=$(get_endpoint_url "s3-website" "$FRONTEND_BUCKET")

echo ""
echo "============================================="
echo " FRONTEND DEPLOY COMPLETE"
echo "============================================="
echo "Frontend URL:  $FRONTEND_URL"
echo "QA Dashboard:  ${FRONTEND_URL}/qa.html"
echo "API Endpoint:  $API_ENDPOINT"
echo "Test Endpoint: $TEST_ENDPOINT"
echo "Read Endpoint: $READ_ENDPOINT"
echo "Catalog Endpoint:  $CATALOG_ENDPOINT"
echo "Orders Endpoint:   $ORDERS_ENDPOINT"
echo "Customers Endpoint: $CUSTOMERS_ENDPOINT"
echo "API Key para /test: $API_KEY_VALUE"
echo ""
echo "Open the frontend URL in your browser to test all flows."
