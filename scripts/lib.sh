#!/usr/bin/env bash

VISIBILITY_TIMEOUT="${VISIBILITY_TIMEOUT:-360}"

validate_resource_suffix() {
    local suffix="$1"
    if [[ ! "$suffix" =~ ^[a-z0-9-]+$ ]]; then
        echo "ERRO: RESOURCE_SUFFIX '$suffix' contem caracteres invalidos."
        echo "  Use apenas letras minusculas, numeros e hifens (ex: 'meu-ambiente-01')."
        exit 1
    fi
    if [ ${#suffix} -lt 1 ]; then
        echo "ERRO: RESOURCE_SUFFIX nao pode ser vazio."
        exit 1
    fi
    if [ ${#suffix} -gt 20 ]; then
        echo "ERRO: RESOURCE_SUFFIX '$suffix' tem ${#suffix} caracteres (maximo 20)."
        exit 1
    fi
    echo "  OK: RESOURCE_SUFFIX '$suffix' possui formato valido."
}

wait_for_iam_role() {
    local role_name="$1"
    echo "Aguardando propagacao do IAM Role $role_name..."
    for i in {1..12}; do
        if aws iam wait role-exists --role-name "$role_name" 2>/dev/null; then
            echo "IAM Role $role_name propagada."
            return 0
        fi
        echo "Tentativa $i/12: role ainda nao propagada, aguardando 5s..."
        sleep 5
    done
    echo "ERRO: IAM Role $role_name nao propagada apos 60 segundos"
    exit 1
}

wait_for_sqs_queue() {
    local queue_name="$1"
    local region="$2"
    echo "Aguardando fila SQS $queue_name..."
    for i in {1..6}; do
        if aws sqs get-queue-url --queue-name "$queue_name" --region "$region" >/dev/null 2>&1; then
            echo "Fila SQS $queue_name disponivel."
            return 0
        fi
        echo "Tentativa $i/6: fila ainda nao disponivel, aguardando 5s..."
        sleep 5
    done
    echo "ERRO: Fila SQS $queue_name nao disponivel apos 30 segundos"
    exit 1
}

load_env() {
    local env_file="${1:-.env}"
    if [ ! -f "$env_file" ]; then
        echo "ERRO: Arquivo $env_file nao encontrado"
        exit 1
    fi
    set -a
    source "$env_file"
    set +a
    if [ "${DEPLOY_TARGET:-aws}" == "localstack" ]; then
        export AWS_ENDPOINT_URL="http://localhost:4566"
    fi
}

get_endpoint_url() {
    local service="$1"
    local identifier="$2"
    local path="${3:-}"
    if [ "${DEPLOY_TARGET:-aws}" == "localstack" ]; then
        case "$service" in
            api) echo "https://${identifier}.execute-api.localhost.localstack.cloud:4566${path}" ;;
            s3-website) echo "http://${identifier}.s3-website.localhost.localstack.cloud:4566" ;;
            *) echo "Unknown service: $service" >&2; exit 1 ;;
        esac
    else
        case "$service" in
            api) echo "https://${identifier}.execute-api.${AWS_REGION}.amazonaws.com${path}" ;;
            s3-website) echo "http://${identifier}.s3-website.${AWS_REGION}.amazonaws.com" ;;
            *) echo "Unknown service: $service" >&2; exit 1 ;;
        esac
    fi
}

poll_resource() {
    local description="$1"
    local max_attempts="$2"
    local interval="$3"
    shift 3
    echo "Aguardando $description..."
    local i=1
    while [ "$i" -le "$max_attempts" ]; do
        if eval "$*"; then
            echo "OK: $description pronto."
            return 0
        fi
        echo "  Tentativa $i/$max_attempts: ainda nao pronto, aguardando ${interval}s..."
        sleep "$interval"
        i=$((i + 1))
    done
    echo "ERRO: $description nao ficou pronto apos $((max_attempts * interval)) segundos"
    return 1
}

validate_env() {
    local missing=0
    for var in "$@"; do
        if [ -z "${!var:-}" ]; then
            echo "ERRO: Variavel $var nao definida no .env"
            missing=1
        fi
    done
    if [ "$missing" -eq 1 ]; then
        exit 1
    fi
    if [[ "$*" == *"RESOURCE_SUFFIX"* ]] && [ -n "${RESOURCE_SUFFIX:-}" ]; then
        validate_resource_suffix "$RESOURCE_SUFFIX"
    fi
}

put_integration_response_cors() {
    local rest_api_id="$1"
    local resource_id="$2"
    local region="$3"
    local tmpfile
    tmpfile=$(mktemp)
    cat > "$tmpfile" << 'EOF'
{"method.response.header.Access-Control-Allow-Headers":"'*'","method.response.header.Access-Control-Allow-Methods":"'*'","method.response.header.Access-Control-Allow-Origin":"'*'"}
EOF
    aws apigateway put-integration-response \
        --rest-api-id "$rest_api_id" \
        --resource-id "$resource_id" \
        --http-method OPTIONS \
        --status-code 200 \
        --response-parameters "file://${tmpfile}" \
        --region "$region"
    rm -f "$tmpfile"
}

sns_subscribe_email() {
    local topic_arn="$1"
    local email="$2"
    local region="$3"
    echo "[VALIDACAO] Verificando inscrição SNS para $email no tópico $topic_arn..."
    local existing
    existing=$(aws sns list-subscriptions-by-topic --topic-arn "$topic_arn" --region "$region" --query "Subscriptions[?Endpoint=='$email'].SubscriptionArn" --output text)
    if [ -n "$existing" ] && [ "$existing" != "None" ] && [ "$existing" != "PendingConfirmation" ]; then
        echo "  OK: Email $email já inscrito (ARN: $existing)"
        return 0
    fi
    if [ "$existing" == "PendingConfirmation" ]; then
        echo "  AVISO: Inscrição para $email já existe mas aguarda confirmação. Verifique sua caixa de entrada."
        return 0
    fi
    local result
    result=$(aws sns subscribe --topic-arn "$topic_arn" --protocol email --notification-endpoint "$email" --region "$region" 2>&1) || true
    local sub_arn
    sub_arn=$(echo "$result" | jq -r '.SubscriptionArn' 2>/dev/null || echo "unknown")
    echo "  OK: Email de confirmação enviado para $email (SubscriptionArn: $sub_arn)"
}

validate_not_empty() {
    local var_name="$1"
    local var_value="$2"
    local description="$3"
    if [ -z "${var_value:-}" ] || [ "${var_value:-}" == "None" ]; then
        echo "ERRO [VALIDACAO]: $description nao encontrado ou vazio (variavel: $var_name)"
        exit 1
    fi
    echo "  OK: $description = $var_value"
}

validate_lambda_config() {
    local function_name="$1"
    local region="$2"
    shift 2
    local required_env=("$@")
    echo "[VALIDACAO] Verificando Lambda $function_name..."
    local config
    config=$(aws lambda get-function-configuration --function-name "$function_name" --region "$region" 2>&1) || {
        echo "ERRO [VALIDACAO]: Lambda $function_name nao encontrada"
        exit 1
    }
    local timeout
    timeout=$(echo "$config" | jq -r '.Timeout // empty')
    if [ "$timeout" != "60" ]; then
        echo "ERRO [VALIDACAO]: Lambda $function_name timeout=$timeout (esperado=60)"
        exit 1
    fi
    local env_json
    env_json=$(echo "$config" | jq -r '.Environment.Variables // {}')
    for var in "${required_env[@]}"; do
        local val
        val=$(echo "$env_json" | jq -r ".$var // empty")
        if [ -z "$val" ]; then
            echo "ERRO [VALIDACAO]: Lambda $function_name sem variavel de ambiente $var"
            exit 1
        fi
    done
    echo "  OK: Lambda $function_name timeout=60, env vars OK"
}

validate_sqs_queue() {
    local queue_url="$1"
    local region="$2"
    local check_dedup="$3"
    echo "[VALIDACAO] Verificando fila SQS $queue_url..."
    if [ -z "$queue_url" ] || [ "$queue_url" == "None" ]; then
        echo "ERRO [VALIDACAO]: URL da fila SQS vazia"
        exit 1
    fi
    local attrs
    attrs=$(aws sqs get-queue-attributes --queue-url "$queue_url" --attribute-names All --region "$region" 2>&1) || {
        echo "ERRO [VALIDACAO]: Nao foi possivel ler atributos da fila $queue_url"
        exit 1
    }
    local vt
    vt=$(echo "$attrs" | jq -r '.Attributes.VisibilityTimeout // empty')
    if [ "$vt" != "$VISIBILITY_TIMEOUT" ]; then
        echo "ERRO [VALIDACAO]: Fila SQS VisibilityTimeout=$vt (esperado=$VISIBILITY_TIMEOUT)"
        exit 1
    fi
    if [ "$check_dedup" == "true" ]; then
        local dedup
        dedup=$(echo "$attrs" | jq -r '.Attributes.ContentBasedDeduplication // "false"')
        if [ "$dedup" != "true" ]; then
            echo "ERRO [VALIDACAO]: Fila FIFO sem ContentBasedDeduplication=true. EventBridge nao consegue entregar mensagens."
            echo "  Delete a fila e rode o deploy novamente para recria-la com a configuracao correta."
            exit 1
        fi
        echo "  OK: ContentBasedDeduplication=true"
    fi
    echo "  OK: Fila SQS VisibilityTimeout=90"
}

validate_sqs_policy() {
    local queue_url="$1"
    local region="$2"
    local queue_arn="$3"
    local expected_principal="$4"
    local expected_action="$5"
    local expected_source="$6"
    echo "[VALIDACAO] Verificando politica da fila SQS $queue_url..."
    local policy_json
    policy_json=$(aws sqs get-queue-attributes --queue-url "$queue_url" --attribute-names Policy --region "$region" --query "Attributes.Policy" --output text 2>&1) || {
        echo "AVISO [VALIDACAO]: Nao foi possivel ler politica da fila (pode ser nova)"
        return 0
    }
    if [ -z "$policy_json" ] || [ "$policy_json" == "None" ]; then
        echo "AVISO [VALIDACAO]: Fila SQS sem politica de acesso"
        return 0
    fi
    if ! echo "$policy_json" | jq -e ".Statement[] | select(.Principal.Service == \"$expected_principal\")" >/dev/null 2>&1; then
        echo "ERRO [VALIDACAO]: Fila nao permite acesso do principal $expected_principal"
        echo "  Politica atual: $policy_json"
        exit 1
    fi
    if ! echo "$policy_json" | jq -e ".Statement[] | select(.Action == \"$expected_action\")" >/dev/null 2>&1; then
        echo "ERRO [VALIDACAO]: Fila nao permite acao $expected_action"
        exit 1
    fi
    local source_arn
    source_arn=$(echo "$policy_json" | jq -r '.Statement[] | select(.Principal.Service == "'$expected_principal'") | .Condition.ArnLike["aws:SourceArn"] // empty' 2>/dev/null)
    if [ -n "$source_arn" ]; then
        echo "  SourceArn na politica: $source_arn"
        if [ -n "$expected_source" ] && [ "$source_arn" != "$expected_source" ]; then
            echo "  AVISO: SourceArn ($source_arn) difere do esperado ($expected_source)"
            echo "  Se o EventBridge nao entregar mensagens, atualize o SourceArn na politica da fila."
        fi
    else
        echo "  AVISO: Politica nao possui condicao aws:SourceArn"
    fi
    echo "  OK: Politica SQS valida para $expected_principal / $expected_action"
}

validate_eventbridge_target() {
    local rule_name="$1"
    local event_bus_name="$2"
    local expected_arn="$3"
    local region="$4"
    echo "[VALIDACAO] Verificando target da rule EventBridge $rule_name..."
    local targets
    targets=$(aws events list-targets-by-rule --rule "$rule_name" --event-bus-name "$event_bus_name" --region "$region" 2>&1) || {
        echo "ERRO [VALIDACAO]: Rule EventBridge $rule_name nao encontrada"
        exit 1
    }
    local count
    count=$(echo "$targets" | jq -r '.Targets | length')
    if [ "$count" -eq 0 ]; then
        echo "ERRO [VALIDACAO]: Rule $rule_name nao possui targets"
        exit 1
    fi
    local target_arn
    target_arn=$(echo "$targets" | jq -r '.Targets[0].Arn')
    if [ "$target_arn" != "$expected_arn" ]; then
        echo "ERRO [VALIDACAO]: Target ARN ($target_arn) difere do esperado ($expected_arn)"
        exit 1
    fi
    local msg_group_id
    msg_group_id=$(echo "$targets" | jq -r '.Targets[0].SqsParameters.MessageGroupId // empty')
    if [ -z "$msg_group_id" ]; then
        echo "ERRO [VALIDACAO]: Target sem SqsParameters.MessageGroupId (obrigatorio para FIFO)"
        exit 1
    fi
    echo "  OK: Rule $rule_name -> $target_arn (MessageGroupId=$msg_group_id)"
}

validate_esm() {
    local function_name="$1"
    local source_arn="$2"
    local region="$3"
    echo "[VALIDACAO] Verificando event source mapping SQS -> Lambda $function_name..."
    local uuid
    uuid=$(aws lambda list-event-source-mappings --function-name "$function_name" --event-source-arn "$source_arn" --region "$region" --query "EventSourceMappings[0].UUID" --output text)
    if [ -z "$uuid" ] || [ "$uuid" == "None" ]; then
        echo "ERRO [VALIDACAO]: Lambda $function_name sem event source mapping para $source_arn"
        exit 1
    fi
    local state
    state=$(aws lambda list-event-source-mappings --function-name "$function_name" --event-source-arn "$source_arn" --region "$region" --query "EventSourceMappings[0].State" --output text)
    if [ "$state" != "Enabled" ]; then
        echo "ERRO [VALIDACAO]: Event source mapping para $function_name no estado $state (esperado: Enabled)"
        exit 1
    fi
    echo "  OK: Event source mapping $uuid (State=$state)"
}

ensure_iam_lambda_role() {
    local role_name="$1"
    if ! aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
        aws iam create-role --role-name "$role_name" --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
        aws iam attach-role-policy --role-name "$role_name" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    fi
    wait_for_iam_role "$role_name"
}

ensure_sqs_dlq() {
    local dlq_name="$1"
    local region="$2"
    local fifo="$3"
    if ! aws sqs get-queue-url --queue-name "$dlq_name" --region "$region" >/dev/null 2>&1; then
        local attrs="{}"
        [ "$fifo" == "true" ] && attrs='{"FifoQueue":"true"}'
        aws sqs create-queue --queue-name "$dlq_name" --attributes "$attrs" --region "$region"
    fi
    local url
    url=$(aws sqs get-queue-url --queue-name "$dlq_name" --region "$region" --query QueueUrl --output text)
    local arn
    arn=$(aws sqs get-queue-attributes --queue-url "$url" --attribute-names QueueArn --query Attributes.QueueArn --output text --region "$region")
    echo "$arn"
}

ensure_sqs_queue() {
    local queue_name="$1"
    local dlq_arn="$2"
    local region="$3"
    local fifo="$4"
    local is_fifo="$5"
    if [ "$fifo" == "true" ]; then
        if ! aws sqs get-queue-url --queue-name "$queue_name" --region "$region" >/dev/null 2>&1; then
            aws sqs create-queue --queue-name "$queue_name" --attributes "{\"FifoQueue\":\"true\",\"ContentBasedDeduplication\":\"true\",\"VisibilityTimeout\":\"$VISIBILITY_TIMEOUT\",\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"$dlq_arn\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"}" --region "$region"
        fi
    else
        if ! aws sqs get-queue-url --queue-name "$queue_name" --region "$region" >/dev/null 2>&1; then
            aws sqs create-queue --queue-name "$queue_name" --attributes "{\"VisibilityTimeout\":\"$VISIBILITY_TIMEOUT\",\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"$dlq_arn\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"}" --region "$region"
        fi
    fi
    local url
    url=$(aws sqs get-queue-url --queue-name "$queue_name" --region "$region" --query QueueUrl --output text)
    local arn
    arn=$(aws sqs get-queue-attributes --queue-url "$url" --attribute-names QueueArn --query Attributes.QueueArn --output text --region "$region")
    aws sqs set-queue-attributes --queue-url "$url" --attributes "{\"VisibilityTimeout\":\"$VISIBILITY_TIMEOUT\"}" --region "$region"
    wait_for_sqs_queue "$queue_name" "$region"
    validate_not_empty "QUEUE_URL" "$url" "$queue_name Queue URL"
    validate_not_empty "QUEUE_ARN" "$arn" "$queue_name Queue ARN"
    validate_sqs_queue "$url" "$region" "$is_fifo"
    QUEUE_URL="$url"
    QUEUE_ARN="$arn"
}

ensure_lambda_function() {
    local lambda_name="$1"
    local role_name="$2"
    local handler="$3"
    local zip_file="$4"
    local region="$5"
    local account_id="$6"
    shift 6
    local env_vars="$*"
    if ! aws lambda get-function --function-name "$lambda_name" --region "$region" >/dev/null 2>&1; then
        echo "Criando funcao Lambda $lambda_name..."
        for i in {1..3}; do
            aws lambda create-function --function-name "$lambda_name" --runtime python3.12 --role "arn:aws:iam::$account_id:role/$role_name" --handler "$handler" --zip-file "fileb://$zip_file" --timeout 60 --region "$region" && break || sleep 10
        done
        aws lambda wait function-active-v2 --function-name "$lambda_name" --region "$region"
    else
        aws lambda update-function-code --function-name "$lambda_name" --zip-file "fileb://$zip_file" --region "$region"
        aws lambda wait function-updated-v2 --function-name "$lambda_name" --region "$region"
    fi
    if [ -n "$env_vars" ]; then
        aws lambda update-function-configuration --function-name "$lambda_name" --timeout 60 --environment "Variables={$env_vars}" --region "$region"
    fi
}

ensure_event_source_mapping() {
    local function_name="$1"
    local source_arn="$2"
    local region="$3"
    local batch_size="${4:-5}"
    local uuid
    uuid=$(aws lambda list-event-source-mappings --function-name "$function_name" --event-source-arn "$source_arn" --region "$region" --query "EventSourceMappings[0].UUID" --output text)
    if [ -z "$uuid" ] || [ "$uuid" == "None" ]; then
        aws lambda create-event-source-mapping --function-name "$function_name" --batch-size "$batch_size" --event-source-arn "$source_arn" --function-response-types "ReportBatchItemFailures" --region "$region"
    else
        local current_types
        current_types=$(aws lambda get-event-source-mapping --uuid "$uuid" --region "$region" --query "FunctionResponseTypes" --output json 2>/dev/null || echo "[]")
        if echo "$current_types" | grep -q "ReportBatchItemFailures"; then
            echo "  OK: Event source mapping $uuid ja possui ReportBatchItemFailures."
        else
            echo "  Atualizando event source mapping $uuid para ReportBatchItemFailures..."
            aws lambda update-event-source-mapping --uuid "$uuid" --function-response-types "ReportBatchItemFailures" --region "$region" >/dev/null 2>&1
        fi
    fi
    validate_esm "$function_name" "$source_arn" "$region"
}

setup_api_cors() {
    local rest_api_id="$1"
    local resource_id="$2"
    local region="$3"
    if ! aws apigateway get-method --rest-api-id "$rest_api_id" --resource-id "$resource_id" --http-method OPTIONS --region "$region" >/dev/null 2>&1; then
        aws apigateway put-method --rest-api-id "$rest_api_id" --resource-id "$resource_id" --http-method OPTIONS --authorization-type "NONE" --region "$region"
    fi
    aws apigateway get-method-response --rest-api-id "$rest_api_id" --resource-id "$resource_id" --http-method OPTIONS --status-code 200 --region "$region" >/dev/null 2>&1 || \
    aws apigateway put-method-response --rest-api-id "$rest_api_id" --resource-id "$resource_id" --http-method OPTIONS --status-code 200 \
        --response-parameters "method.response.header.Access-Control-Allow-Headers=true,method.response.header.Access-Control-Allow-Methods=true,method.response.header.Access-Control-Allow-Origin=true" \
        --region "$region"
    aws apigateway get-integration --rest-api-id "$rest_api_id" --resource-id "$resource_id" --http-method OPTIONS --region "$region" >/dev/null 2>&1 || \
    aws apigateway put-integration --rest-api-id "$rest_api_id" --resource-id "$resource_id" --http-method OPTIONS --type MOCK \
        --request-templates '{"application/json":"{\"statusCode\":200}"}' --region "$region"
    aws apigateway get-integration-response --rest-api-id "$rest_api_id" --resource-id "$resource_id" --http-method OPTIONS --status-code 200 --region "$region" >/dev/null 2>&1 || \
    put_integration_response_cors "$rest_api_id" "$resource_id" "$region"
}

put_eventbridge_target() {
    local rule_name="$1"
    local event_bus_name="$2"
    local queue_arn="$3"
    local message_group_id="$4"
    local region="$5"
    local tmpfile
    tmpfile=$(mktemp)
    cat > "$tmpfile" << EOF
[
  {
    "Id": "1",
    "Arn": "$queue_arn",
    "SqsParameters": {
      "MessageGroupId": "$message_group_id"
    }
  }
]
EOF
    aws events put-targets --rule "$rule_name" --event-bus-name "$event_bus_name" --targets "file://${tmpfile}" --region "$region"
    rm -f "$tmpfile"
}
