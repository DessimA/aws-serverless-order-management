#!/usr/bin/env bash
set -euo pipefail

if [ ! -f .env ]; then echo "Error: .env missing"; exit 1; fi

chmod +x scripts/*.sh

echo "Starting Deployment Pipeline..."
cd scripts
./validate-flow.sh
cd ..
echo "Deployment and Validation Complete"
