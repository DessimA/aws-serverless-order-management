#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source "$SCRIPT_DIR/lib.sh"

load_env "$SCRIPT_DIR/../.env"
validate_env "AWS_REGION" "RESOURCE_SUFFIX"

TABLE_NAME="course-catalog-${RESOURCE_SUFFIX}"

echo "============================================="
echo " SEEDING CATALOG TABLE: $TABLE_NAME"
echo "============================================="

if ! aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "ERRO: Table $TABLE_NAME does not exist. Run deploy-catalog.sh first."
    exit 1
fi

aws dynamodb put-item --table-name "$TABLE_NAME" --item '{
    "cursoId":{"S":"AWS-CP-001"},
    "nome":{"S":"AWS Cloud Practitioner"},
    "descricao":{"S":"Fundamentos de cloud computing e servicos AWS para iniciantes"},
    "provider":{"S":"AWS"},
    "tipo":{"S":"curso"},
    "nivel":{"S":"Iniciante"},
    "preco":{"N":"149.90"},
    "duracao":{"S":"40h"},
    "disponivel":{"BOOL":true}
}' --region "$AWS_REGION" >/dev/null

aws dynamodb put-item --table-name "$TABLE_NAME" --item '{
    "cursoId":{"S":"AWS-SAA-001"},
    "nome":{"S":"AWS Solutions Architect Associate"},
    "descricao":{"S":"Arquitetura de solucoes escalaveis e resilientes na AWS"},
    "provider":{"S":"AWS"},
    "tipo":{"S":"curso"},
    "nivel":{"S":"Intermediario"},
    "preco":{"N":"249.90"},
    "duracao":{"S":"60h"},
    "disponivel":{"BOOL":true}
}' --region "$AWS_REGION" >/dev/null

aws dynamodb put-item --table-name "$TABLE_NAME" --item '{
    "cursoId":{"S":"AWS-DVA-001"},
    "nome":{"S":"AWS Developer Associate"},
    "descricao":{"S":"Desenvolvimento de aplicacoes nativas em cloud na AWS"},
    "provider":{"S":"AWS"},
    "tipo":{"S":"curso"},
    "nivel":{"S":"Intermediario"},
    "preco":{"N":"199.90"},
    "duracao":{"S":"50h"},
    "disponivel":{"BOOL":true}
}' --region "$AWS_REGION" >/dev/null

aws dynamodb put-item --table-name "$TABLE_NAME" --item '{
    "cursoId":{"S":"AWS-SOA-001"},
    "nome":{"S":"AWS SysOps Administrator"},
    "descricao":{"S":"Operacoes, monitoramento e automacao de infraestrutura AWS"},
    "provider":{"S":"AWS"},
    "tipo":{"S":"curso"},
    "nivel":{"S":"Intermediario"},
    "preco":{"N":"199.90"},
    "duracao":{"S":"50h"},
    "disponivel":{"BOOL":true}
}' --region "$AWS_REGION" >/dev/null

aws dynamodb put-item --table-name "$TABLE_NAME" --item '{
    "cursoId":{"S":"AWS-SAP-001"},
    "nome":{"S":"AWS Solutions Architect Professional"},
    "descricao":{"S":"Arquitetura avancada para workloads complexos e hibridos na AWS"},
    "provider":{"S":"AWS"},
    "tipo":{"S":"curso"},
    "nivel":{"S":"Avancado"},
    "preco":{"N":"349.90"},
    "duracao":{"S":"80h"},
    "disponivel":{"BOOL":true}
}' --region "$AWS_REGION" >/dev/null

aws dynamodb put-item --table-name "$TABLE_NAME" --item '{
    "cursoId":{"S":"AWS-CP-VOC-001"},
    "nome":{"S":"Voucher Exame AWS Cloud Practitioner"},
    "descricao":{"S":"Voucher para realizacao do exame oficial AWS Cloud Practitioner (CLF-C02)"},
    "provider":{"S":"AWS"},
    "tipo":{"S":"voucher"},
    "nivel":{"S":"Iniciante"},
    "preco":{"N":"399.00"},
    "disponivel":{"BOOL":true}
}' --region "$AWS_REGION" >/dev/null

aws dynamodb put-item --table-name "$TABLE_NAME" --item '{
    "cursoId":{"S":"AWS-SAA-VOC-001"},
    "nome":{"S":"Voucher Exame AWS Solutions Architect Associate"},
    "descricao":{"S":"Voucher para realizacao do exame oficial AWS SAA-C03"},
    "provider":{"S":"AWS"},
    "tipo":{"S":"voucher"},
    "nivel":{"S":"Intermediario"},
    "preco":{"N":"499.00"},
    "disponivel":{"BOOL":true}
}' --region "$AWS_REGION" >/dev/null

aws dynamodb put-item --table-name "$TABLE_NAME" --item '{
    "cursoId":{"S":"AZ-900-001"},
    "nome":{"S":"Azure Fundamentals AZ-900"},
    "descricao":{"S":"Fundamentos de cloud computing e servicos Microsoft Azure"},
    "provider":{"S":"Azure"},
    "tipo":{"S":"curso"},
    "nivel":{"S":"Iniciante"},
    "preco":{"N":"149.90"},
    "duracao":{"S":"35h"},
    "disponivel":{"BOOL":true}
}' --region "$AWS_REGION" >/dev/null

aws dynamodb put-item --table-name "$TABLE_NAME" --item '{
    "cursoId":{"S":"AZ-104-001"},
    "nome":{"S":"Azure Administrator AZ-104"},
    "descricao":{"S":"Administracao de recursos e identidade no Microsoft Azure"},
    "provider":{"S":"Azure"},
    "tipo":{"S":"curso"},
    "nivel":{"S":"Intermediario"},
    "preco":{"N":"229.90"},
    "duracao":{"S":"55h"},
    "disponivel":{"BOOL":true}
}' --region "$AWS_REGION" >/dev/null

aws dynamodb put-item --table-name "$TABLE_NAME" --item '{
    "cursoId":{"S":"GCP-ACE-001"},
    "nome":{"S":"Google Cloud Associate Cloud Engineer"},
    "descricao":{"S":"Implantacao e gerenciamento de solucoes no Google Cloud"},
    "provider":{"S":"GCP"},
    "tipo":{"S":"curso"},
    "nivel":{"S":"Intermediario"},
    "preco":{"N":"229.90"},
    "duracao":{"S":"55h"},
    "disponivel":{"BOOL":true}
}' --region "$AWS_REGION" >/dev/null

aws dynamodb put-item --table-name "$TABLE_NAME" --item '{
    "cursoId":{"S":"GCP-PCA-001"},
    "nome":{"S":"Google Cloud Professional Cloud Architect"},
    "descricao":{"S":"Arquitetura de solucoes empresariais no Google Cloud Platform"},
    "provider":{"S":"GCP"},
    "tipo":{"S":"curso"},
    "nivel":{"S":"Avancado"},
    "preco":{"N":"299.90"},
    "duracao":{"S":"70h"},
    "disponivel":{"BOOL":false}
}' --region "$AWS_REGION" >/dev/null

ITEM_COUNT=$(aws dynamodb scan --table-name "$TABLE_NAME" --select COUNT --region "$AWS_REGION" --query Count --output text)
echo ""
echo "============================================="
echo " SEED COMPLETE"
echo "============================================="
echo "Total items in catalog: $ITEM_COUNT"
