# Terraform Infrastructure

## Visao Geral

A infraestrutura do CloudCert foi migrada de 8 scripts Bash + AWS CLI para
Terraform. O diretorio `terraform/` contem toda a configuracao de infraestrutura
como codigo (IaC), mantendo nomes de recursos identicos aos originais.

## Estrutura

```
terraform/
  providers.tf          - Providers AWS, Random, Local, Archive
  variables.tf          - Variaveis de entrada
  locals.tf             - Calculo de nomes de recursos
  outputs.tf            - Outputs (URLs, ARNs, chaves)
  data.tf               - Archive data sources para Lambdas
  sns.tf                - Topico SNS + subscription email
  eventbus.tf           - EventBridge event bus
  dynamodb.tf           - Tabelas DynamoDB
  iam.tf                - Roles e policies para Lambdas
  sqs.tf                - Filas SQS + DLQs (via modulo)
  lambda_functions.tf   - Funcoes Lambda + log groups + ESM
  eventbridge_rules.tf  - Regras EventBridge + targets
  api_gateway.tf        - API Gateway REST + recursos + metodos
  s3.tf                 - Buckets S3 (dados e frontend)
  cloudwatch.tf         - (vazio: alarmes no modulo, logs nas Lambdas)
  secrets.tf            - JWT secret + API key locais
  frontend.tf           - Upload de assets do frontend
  modules/
    sqs_with_dlq/       - Modulo reutilizavel SQS + DLQ + alarme
  builds/               - Zips das Lambdas (gerados pelo Terraform)
```

## Como Inicializar

```bash
cd terraform
terraform init
```

O provider AWS ja configura endpoints LocalStack automaticamente quando
`deploy_target = "localstack"`.

## Como Aplicar

### Via run.sh

```bash
./run.sh
```

O script `run.sh` executa `validate-flow.sh`, que gera o tfvars com
`generate-tfvars.sh` e executa `terraform apply -auto-approve`.

### Diretamente

```bash
bash scripts/generate-tfvars.sh
cd terraform && terraform apply -auto-approve
```

## Como Destruir

```bash
./cleanup.sh
```

O novo `cleanup.sh` executa `generate-tfvars.sh` e `terraform destroy`.

## Mapa de Arquivos .tf para Recursos AWS

| Arquivo | Recursos |
|---|---|
| `sns.tf` | SNS Topic, Subscription |
| `eventbus.tf` | EventBridge Event Bus |
| `dynamodb.tf` | 4 tabelas DynamoDB |
| `iam.tf` | 10 roles + policies IAM |
| `sqs.tf` | 5 filas + 5 DLQs + policies |
| `lambda_functions.tf` | 10 Lambdas + log groups + ESMs |
| `eventbridge_rules.tf` | 3 regras + 3 targets SQS |
| `api_gateway.tf` | REST API, recursos, metodos, deployment, usage plan |
| `s3.tf` | 2 buckets + notificacao + website |
| `secrets.tf` | JWT secret, API key locais |
| `frontend.tf` | 6 objetos S3 do frontend |

## Modulo sqs_with_dlq

Modulo reutilizavel que cria:
- Fila SQS principal com redrive policy para DLQ
- Fila DLQ
- Alarme CloudWatch para monitoramento da DLQ

Suporta filas FIFO e standard, com configuracao de visibility timeout e
content-based deduplication.

## Suporte a LocalStack

Quando `deploy_target = "localstack"`, o provider AWS:
- Usa credenciais dummy (`test`/`test`)
- Ignora validacao de credenciais e metadata API
- Configura endpoints para `http://localhost:4566` em todos os servicos
- As URLs de API e frontend usam o formato localstack.cloud

## Gerenciamento do JWT Secret

O `random_password` gera 64 caracteres alfanumericos que persistem no state do
Terraform. O secret e escrito em `scripts/.jwt-secret` para compatibilidade com
os scripts de validacao. O mesmo mecanismo e usado para a API key.

## Geracao dos Zips Lambda

Cada Lambda usa um data source `archive_file` que empacota:
- O `index.py` especifico da funcao
- Os 6 modulos `common/` (`__init__.py`, `auth.py`, `http.py`, `sns.py`, `sqs.py`, `utils.py`)

Os zips sao gerados em `terraform/builds/` e referenciados pelo `filename` e
`source_code_hash` de cada `aws_lambda_function`.

## validate-flow.sh como Gate de Aceitacao

O script `validate-flow.sh` continua sendo o entry point de validacao de ponta
a ponta. A diferenca e que o bloco de deploy agora usa Terraform em vez de
chamar os 8 scripts individuais. Os 25 testes de aceitacao permanecem
identicos.
