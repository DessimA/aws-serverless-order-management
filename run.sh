#!/usr/bin/env bash
set -euo pipefail

if [ ! -f .env ]; then echo "Error: .env missing"; exit 1; fi

chmod +x scripts/*.sh

echo "Starting Deployment Pipeline..."
cd scripts
./deploy-api-flow.sh
./deploy-s3-flow.sh
./deploy-order-processor.sh
./deploy-lifecycle-ops.sh
./deploy-frontend.sh
./validate-flow.sh
cd ..
echo "Deployment and Validation Complete"
