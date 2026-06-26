#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
load_env "$SCRIPT_DIR/../.env"

cat > "$SCRIPT_DIR/../terraform/terraform.tfvars" << EOF
aws_region         = "${AWS_REGION}"
resource_suffix    = "${RESOURCE_SUFFIX}"
notification_email = "${NOTIFICATION_EMAIL:-}"
deploy_target      = "${DEPLOY_TARGET:-localstack}"
allowed_source_ip  = "${ALLOWED_SOURCE_IP:-}"
EOF

echo "terraform/terraform.tfvars gerado."
