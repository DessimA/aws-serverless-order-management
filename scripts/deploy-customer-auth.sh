#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source "$SCRIPT_DIR/lib.sh"

load_env "$SCRIPT_DIR/../.env"
validate_env "AWS_REGION" "RESOURCE_SUFFIX"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

ROLE_NAME="customer-auth-role-${RESOURCE_SUFFIX}"
LAMBDA_NAME="customer-auth-${RESOURCE_SUFFIX}"
TABLE_NAME="customer-data-${RESOURCE_SUFFIX}"
REST_API_NAME="order-ingestion-api-${RESOURCE_SUFFIX}"
JWT_SECRET_FILE="$SCRIPT_DIR/.jwt-secret"

echo "============================================="
echo " DEPLOY CUSTOMER AUTH"
echo "============================================="

# === DynamoDB Table ===
if ! aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws dynamodb create-table --table-name "$TABLE_NAME" \
        --attribute-definitions AttributeName=email,AttributeType=S \
        --key-schema AttributeName=email,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST --region "$AWS_REGION"
    aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$AWS_REGION"
fi
TABLE_ARN=$(aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$AWS_REGION" --query Table.TableArn --output text)
validate_not_empty "TABLE_ARN" "$TABLE_ARN" "Customer DynamoDB Table ARN"

# === IAM Role ===
ensure_iam_lambda_role "$ROLE_NAME"

aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "CustomerAuthDynamoDB" --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"dynamodb:PutItem\",\"dynamodb:GetItem\"],\"Resource\":\"$TABLE_ARN\"}]}"

# === JWT Secret ===
ensure_jwt_secret "$JWT_SECRET_FILE"

# === Lambda Deployment ===
PKG_DIR=$(mktemp -d)
cp ../src/customer_auth/index.py "$PKG_DIR/"
mkdir -p "$PKG_DIR/common"
cp ../src/common/*.py "$PKG_DIR/common/"
cd "$PKG_DIR"
zip -qr "$SCRIPT_DIR/lambda_deploy_customer_auth.zip" .
cd "$SCRIPT_DIR"
rm -rf "$PKG_DIR"

ensure_lambda_function "$LAMBDA_NAME" "$ROLE_NAME" "index.lambda_handler" "lambda_deploy_customer_auth.zip" "$AWS_REGION" "$ACCOUNT_ID" "5" "DYNAMODB_TABLE=$TABLE_NAME,JWT_SECRET=$JWT_SECRET_VALUE"
validate_lambda_config "$LAMBDA_NAME" "$AWS_REGION" "DYNAMODB_TABLE" "JWT_SECRET"

# === API Gateway Resources ===
REST_API_ID=$(aws apigateway get-rest-apis --region "$AWS_REGION" \
    --query "items[?name=='$REST_API_NAME'].id" --output text)
if [ -z "$REST_API_ID" ] || [ "$REST_API_ID" == "None" ]; then
    echo "ERRO: REST API $REST_API_NAME not found. Deploy api-flow first."
    exit 1
fi
validate_not_empty "REST_API_ID" "$REST_API_ID" "REST API ID"

ROOT_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$REST_API_ID" --region "$AWS_REGION" \
    --query "items[?path=='/'].id" --output text)

# Resource: /customers
CUSTOMERS_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$REST_API_ID" --region "$AWS_REGION" \
    --query "items[?path=='/customers'].id" --output text)
if [ -z "$CUSTOMERS_RESOURCE_ID" ] || [ "$CUSTOMERS_RESOURCE_ID" == "None" ]; then
    CUSTOMERS_RESOURCE_ID=$(aws apigateway create-resource --rest-api-id "$REST_API_ID" \
        --parent-id "$ROOT_RESOURCE_ID" --path-part "customers" --region "$AWS_REGION" --query id --output text)
    echo "Created resource /customers"
fi
validate_not_empty "CUSTOMERS_RESOURCE_ID" "$CUSTOMERS_RESOURCE_ID" "/customers resource ID"

# Resource: /customers/register
REGISTER_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$REST_API_ID" --region "$AWS_REGION" \
    --query "items[?path=='/customers/register'].id" --output text)
if [ -z "$REGISTER_RESOURCE_ID" ] || [ "$REGISTER_RESOURCE_ID" == "None" ]; then
    REGISTER_RESOURCE_ID=$(aws apigateway create-resource --rest-api-id "$REST_API_ID" \
        --parent-id "$CUSTOMERS_RESOURCE_ID" --path-part "register" --region "$AWS_REGION" --query id --output text)
    echo "Created resource /customers/register"
fi
validate_not_empty "REGISTER_RESOURCE_ID" "$REGISTER_RESOURCE_ID" "/customers/register resource ID"

# Resource: /customers/login
LOGIN_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$REST_API_ID" --region "$AWS_REGION" \
    --query "items[?path=='/customers/login'].id" --output text)
if [ -z "$LOGIN_RESOURCE_ID" ] || [ "$LOGIN_RESOURCE_ID" == "None" ]; then
    LOGIN_RESOURCE_ID=$(aws apigateway create-resource --rest-api-id "$REST_API_ID" \
        --parent-id "$CUSTOMERS_RESOURCE_ID" --path-part "login" --region "$AWS_REGION" --query id --output text)
    echo "Created resource /customers/login"
fi
validate_not_empty "LOGIN_RESOURCE_ID" "$LOGIN_RESOURCE_ID" "/customers/login resource ID"

# Resource: /customers/me
ME_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$REST_API_ID" --region "$AWS_REGION" \
    --query "items[?path=='/customers/me'].id" --output text)
if [ -z "$ME_RESOURCE_ID" ] || [ "$ME_RESOURCE_ID" == "None" ]; then
    ME_RESOURCE_ID=$(aws apigateway create-resource --rest-api-id "$REST_API_ID" \
        --parent-id "$CUSTOMERS_RESOURCE_ID" --path-part "me" --region "$AWS_REGION" --query id --output text)
    echo "Created resource /customers/me"
fi
validate_not_empty "ME_RESOURCE_ID" "$ME_RESOURCE_ID" "/customers/me resource ID"

FUNCTION_ARN="arn:aws:lambda:$AWS_REGION:$ACCOUNT_ID:function:$LAMBDA_NAME"

deploy_auth_endpoint() {
    local resource_id="$1"
    local http_method="$2"
    local handler_name="$3"
    local statement_id="$4"

    if ! aws apigateway get-method --rest-api-id "$REST_API_ID" --resource-id "$resource_id" --http-method "$http_method" --region "$AWS_REGION" >/dev/null 2>&1; then
        aws apigateway put-method --rest-api-id "$REST_API_ID" --resource-id "$resource_id" \
            --http-method "$http_method" --authorization-type "NONE" --region "$AWS_REGION"
    fi

    aws apigateway get-integration --rest-api-id "$REST_API_ID" --resource-id "$resource_id" --http-method "$http_method" --region "$AWS_REGION" >/dev/null 2>&1 || \
    aws apigateway put-integration --rest-api-id "$REST_API_ID" --resource-id "$resource_id" \
        --http-method "$http_method" --type AWS_PROXY --integration-http-method POST \
        --uri "arn:aws:apigateway:$AWS_REGION:lambda:path/2015-03-31/functions/$FUNCTION_ARN/invocations" \
        --region "$AWS_REGION"

    setup_api_cors "$REST_API_ID" "$resource_id" "$AWS_REGION"

    aws lambda remove-permission --function-name "$LAMBDA_NAME" --statement-id "$statement_id" \
        --region "$AWS_REGION" 2>/dev/null || true
    aws lambda add-permission --function-name "$LAMBDA_NAME" --statement-id "$statement_id" \
        --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
        --source-arn "arn:aws:execute-api:$AWS_REGION:$ACCOUNT_ID:$REST_API_ID/*/$http_method/$handler_name" \
        --region "$AWS_REGION"
}

# POST /customers/register
deploy_auth_endpoint "$REGISTER_RESOURCE_ID" "POST" "customers/register" "apigateway-customer-register"

# POST /customers/login
deploy_auth_endpoint "$LOGIN_RESOURCE_ID" "POST" "customers/login" "apigateway-customer-login"

# GET /customers/me
deploy_auth_endpoint "$ME_RESOURCE_ID" "GET" "customers/me" "apigateway-customer-me"

# Deploy API changes
aws apigateway create-deployment --rest-api-id "$REST_API_ID" --stage-name prod --region "$AWS_REGION" >/dev/null
echo "API Gateway deployment updated with customer auth endpoints."

REGISTER_ENDPOINT=$(get_endpoint_url "api" "$REST_API_ID" "/prod/customers/register")
LOGIN_ENDPOINT=$(get_endpoint_url "api" "$REST_API_ID" "/prod/customers/login")
ME_ENDPOINT=$(get_endpoint_url "api" "$REST_API_ID" "/prod/customers/me")

rm -f lambda_deploy_customer_auth.zip

echo ""
echo "============================================="
echo " CUSTOMER AUTH DEPLOY COMPLETE"
echo "============================================="
echo "Register: $REGISTER_ENDPOINT"
echo "Login:    $LOGIN_ENDPOINT"
echo "Me:       $ME_ENDPOINT"
