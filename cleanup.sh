#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/lib.sh"
load_env "$SCRIPT_DIR/.env"
validate_env "RESOURCE_SUFFIX" "AWS_REGION"

echo "=== INICIANDO LIMPEZA PARA SUFFIX: $RESOURCE_SUFFIX ==="

bash "$SCRIPT_DIR/scripts/generate-tfvars.sh"

cd "$SCRIPT_DIR"
docker compose run --rm terraform init -upgrade
docker compose run --rm terraform destroy -auto-approve

echo "=== LIMPEZA CONCLUIDA PARA SUFFIX: $RESOURCE_SUFFIX ==="
