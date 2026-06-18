#!/usr/bin/env bash

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
