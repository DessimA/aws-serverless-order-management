#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source "$SCRIPT_DIR/lib.sh"

load_env "$SCRIPT_DIR/../.env"
validate_env "AWS_REGION" "RESOURCE_SUFFIX"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

ROLE_NAME="catalog-reader-role-${RESOURCE_SUFFIX}"
LAMBDA_NAME="catalog-reader-${RESOURCE_SUFFIX}"
TABLE_NAME="course-catalog-${RESOURCE_SUFFIX}"
REST_API_NAME="order-ingestion-api-${RESOURCE_SUFFIX}"

echo "============================================="
echo " DEPLOY CATALOG READER"
echo "============================================="

# === DynamoDB Table ===
if ! aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws dynamodb create-table --table-name "$TABLE_NAME" \
        --attribute-definitions AttributeName=cursoId,AttributeType=S \
        --key-schema AttributeName=cursoId,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST --region "$AWS_REGION"
    aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$AWS_REGION"
fi
TABLE_ARN=$(aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$AWS_REGION" --query Table.TableArn --output text)
validate_not_empty "TABLE_ARN" "$TABLE_ARN" "Catalog DynamoDB Table ARN"

# === IAM Role ===
ensure_iam_lambda_role "$ROLE_NAME"

aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "CatalogReaderDynamoDB" --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"dynamodb:Scan\",\"dynamodb:GetItem\"],\"Resource\":\"$TABLE_ARN\"}]}"

# === Lambda Deployment ===
PKG_DIR=$(mktemp -d)
cp ../src/catalog_reader/index.py "$PKG_DIR/"
mkdir -p "$PKG_DIR/common"
cp ../src/common/*.py "$PKG_DIR/common/"
cd "$PKG_DIR"
zip -qr "$SCRIPT_DIR/lambda_deploy_catalog.zip" .
cd "$SCRIPT_DIR"
rm -rf "$PKG_DIR"

ensure_lambda_function "$LAMBDA_NAME" "$ROLE_NAME" "index.lambda_handler" "lambda_deploy_catalog.zip" "$AWS_REGION" "$ACCOUNT_ID" "10" "DYNAMODB_TABLE=$TABLE_NAME"

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

# Resource: /catalog
CATALOG_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$REST_API_ID" --region "$AWS_REGION" \
    --query "items[?path=='/catalog'].id" --output text)
if [ -z "$CATALOG_RESOURCE_ID" ] || [ "$CATALOG_RESOURCE_ID" == "None" ]; then
    CATALOG_RESOURCE_ID=$(aws apigateway create-resource --rest-api-id "$REST_API_ID" \
        --parent-id "$ROOT_RESOURCE_ID" --path-part "catalog" --region "$AWS_REGION" --query id --output text)
    echo "Created resource /catalog"
fi
validate_not_empty "CATALOG_RESOURCE_ID" "$CATALOG_RESOURCE_ID" "/catalog resource ID"

# Resource: /catalog/{cursoId}
CURSO_ID_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$REST_API_ID" --region "$AWS_REGION" \
    --query "items[?path=='/catalog/{cursoId}'].id" --output text)
if [ -z "$CURSO_ID_RESOURCE_ID" ] || [ "$CURSO_ID_RESOURCE_ID" == "None" ]; then
    CURSO_ID_RESOURCE_ID=$(aws apigateway create-resource --rest-api-id "$REST_API_ID" \
        --parent-id "$CATALOG_RESOURCE_ID" --path-part "{cursoId}" --region "$AWS_REGION" --query id --output text)
    echo "Created resource /catalog/{cursoId}"
fi
validate_not_empty "CURSO_ID_RESOURCE_ID" "$CURSO_ID_RESOURCE_ID" "/catalog/{cursoId} resource ID"

FUNCTION_ARN="arn:aws:lambda:$AWS_REGION:$ACCOUNT_ID:function:$LAMBDA_NAME"

# GET /catalog
if ! aws apigateway get-method --rest-api-id "$REST_API_ID" --resource-id "$CATALOG_RESOURCE_ID" --http-method GET --region "$AWS_REGION" >/dev/null 2>&1; then
    aws apigateway put-method --rest-api-id "$REST_API_ID" --resource-id "$CATALOG_RESOURCE_ID" \
        --http-method GET --authorization-type "NONE" --region "$AWS_REGION"
fi

aws apigateway get-integration --rest-api-id "$REST_API_ID" --resource-id "$CATALOG_RESOURCE_ID" --http-method GET --region "$AWS_REGION" >/dev/null 2>&1 || \
aws apigateway put-integration --rest-api-id "$REST_API_ID" --resource-id "$CATALOG_RESOURCE_ID" \
    --http-method GET --type AWS_PROXY --integration-http-method POST \
    --uri "arn:aws:apigateway:$AWS_REGION:lambda:path/2015-03-31/functions/$FUNCTION_ARN/invocations" \
    --region "$AWS_REGION"

setup_api_cors "$REST_API_ID" "$CATALOG_RESOURCE_ID" "$AWS_REGION"

aws lambda remove-permission --function-name "$LAMBDA_NAME" --statement-id apigateway-catalog-list \
    --region "$AWS_REGION" 2>/dev/null || true
aws lambda add-permission --function-name "$LAMBDA_NAME" --statement-id apigateway-catalog-list \
    --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:$AWS_REGION:$ACCOUNT_ID:$REST_API_ID/*/GET/catalog" \
    --region "$AWS_REGION"

# GET /catalog/{cursoId}
if ! aws apigateway get-method --rest-api-id "$REST_API_ID" --resource-id "$CURSO_ID_RESOURCE_ID" --http-method GET --region "$AWS_REGION" >/dev/null 2>&1; then
    aws apigateway put-method --rest-api-id "$REST_API_ID" --resource-id "$CURSO_ID_RESOURCE_ID" \
        --http-method GET --authorization-type "NONE" \
        --request-parameters "method.request.path.cursoId=true" --region "$AWS_REGION"
fi

aws apigateway get-integration --rest-api-id "$REST_API_ID" --resource-id "$CURSO_ID_RESOURCE_ID" --http-method GET --region "$AWS_REGION" >/dev/null 2>&1 || \
aws apigateway put-integration --rest-api-id "$REST_API_ID" --resource-id "$CURSO_ID_RESOURCE_ID" \
    --http-method GET --type AWS_PROXY --integration-http-method POST \
    --uri "arn:aws:apigateway:$AWS_REGION:lambda:path/2015-03-31/functions/$FUNCTION_ARN/invocations" \
    --region "$AWS_REGION"

setup_api_cors "$REST_API_ID" "$CURSO_ID_RESOURCE_ID" "$AWS_REGION"

aws lambda remove-permission --function-name "$LAMBDA_NAME" --statement-id apigateway-catalog-get \
    --region "$AWS_REGION" 2>/dev/null || true
aws lambda add-permission --function-name "$LAMBDA_NAME" --statement-id apigateway-catalog-get \
    --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:$AWS_REGION:$ACCOUNT_ID:$REST_API_ID/*/GET/catalog/{cursoId}" \
    --region "$AWS_REGION"

# Deploy API changes
aws apigateway create-deployment --rest-api-id "$REST_API_ID" --stage-name prod --region "$AWS_REGION" >/dev/null
echo "API Gateway deployment updated with catalog endpoints."

CATALOG_ENDPOINT=$(get_endpoint_url "api" "$REST_API_ID" "/prod/catalog")
CATALOG_ITEM_ENDPOINT=$(get_endpoint_url "api" "$REST_API_ID" "/prod/catalog/{cursoId}")

rm -f lambda_deploy_catalog.zip

echo ""
echo "============================================="
echo " CATALOG READER DEPLOY COMPLETE"
echo "============================================="
echo "Catalog List:  $CATALOG_ENDPOINT"
echo "Catalog Item:  $CATALOG_ITEM_ENDPOINT"
