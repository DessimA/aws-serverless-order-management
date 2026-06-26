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

echo "=== REMOVENDO VOLUME PERSISTENTE DO LOCALSTACK ==="
LOCALSTACK_VOLUME=$(docker inspect localstack_students --format '{{range .Mounts}}{{if eq .Destination "/var/lib/localstack"}}{{.Name}}{{end}}{{end}}' 2>/dev/null || true)
if [ -n "$LOCALSTACK_VOLUME" ]; then
  docker compose down
  docker volume rm "$LOCALSTACK_VOLUME"
  docker compose up -d
fi

echo "=== LIMPEZA CONCLUIDA PARA SUFFIX: $RESOURCE_SUFFIX ==="
