#!/usr/bin/env bash

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

ensure_log_groups() {
    local suffix="${1:?RESOURCE_SUFFIX required}"
    for name in \
        "order-pre-validator-${suffix}" \
        "order-validator-${suffix}" \
        "order-persister-${suffix}" \
        "order-lifecycle-cancel-${suffix}" \
        "order-lifecycle-update-${suffix}" \
        "order-file-validator-${suffix}" \
        "customer-auth-${suffix}" \
        "order-gateway-${suffix}" \
        "catalog-reader-${suffix}" \
        "test-controller-${suffix}"
    do
        aws logs create-log-group --log-group-name "/aws/lambda/${name}" 2>/dev/null || true
        aws logs put-retention-policy --log-group-name "/aws/lambda/${name}" --retention-in-days 14 2>/dev/null || true
    done
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
