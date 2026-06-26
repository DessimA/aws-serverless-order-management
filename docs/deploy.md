# Deploy e Validacao

## Provisionamento com Terraform

A infraestrutura e provisionada via Terraform (diretorio `terraform/`). O
script `scripts/generate-tfvars.sh` gera `terraform/terraform.tfvars` a partir
das variaveis do `.env`.

### Fluxo de deploy

1. `scripts/generate-tfvars.sh` - Gera o arquivo tfvars
2. `terraform init -upgrade` - Inicializa providers e modulos
3. `terraform apply -auto-approve` - Provisiona ou atualiza recursos
4. `scripts/seed-catalog.sh` - Popula o catalogo DynamoDB

### Recursos provisionados

| Arquivo .tf | Recursos AWS |
|---|---|
| `sns.tf` | Topico SNS `order-notifications-*` + subscription email |
| `eventbus.tf` | EventBridge `orders-event-bus-*` |
| `dynamodb.tf` | 4 tabelas: production (com GSI), audit (com TTL), catalog, customer |
| `iam.tf` | 10 roles IAM com politicas de menor privilegio |
| `sqs.tf` | 5 filas SQS + 5 DLQs + policies (eventbridge e s3) |
| `lambda_functions.tf` | 10 funcoes Lambda + event source mappings |
| `eventbridge_rules.tf` | 3 regras + targets SQS |
| `api_gateway.tf` | REST API, 11 recursos, CORS, deployment, usage plan, api key |
| `cloudwatch.tf` | 10 log groups CloudWatch das Lambdas, retencao de 14 dias |
| `s3.tf` | Buckets de dados e frontend (static website) |
| `secrets.tf` | JWT secret (random_password) + API key (arquivos locais) |
| `frontend.tf` | Upload de assets (index.html, qa.html, style.css, js, config.js) |

### Modulo sqs_with_dlq

Modulo reutilizavel em `terraform/modules/sqs_with_dlq/` que cria:
- Fila SQS principal com redrive policy (maxReceiveCount=3)
- Fila DLQ
- Alarme CloudWatch (ApproximateNumberOfMessagesVisible >= 1) com acao SNS

Suporta filas FIFO e standard, visibility timeout configuravel.

### Scripts de suporte

| Script | Finalidade |
|---|---|
| `lib.sh` | Biblioteca compartilhada (6 funcoes utilitarias) |
| `generate-tfvars.sh` | Gera terraform.tfvars a partir do .env |
| `seed-catalog.sh` | Upsert de 11 itens no catalogo (1 com disponivel=false) |
| `validate-flow.sh` | Deploy completo + 25 testes E2E |

## `validate-flow.sh`

Gate de aceitacao que executa deploy via Terraform e 25 testes de ponta a ponta:

1. POST /orders - criacao de pedido
1b. Duplicidade - reenvio nao sobrescreve
2. S3 File Upload - auditoria batch
3. Cancel - via EventBridge
4. Update - via EventBridge
4b. Cancel + Update - estado terminal CANCELLED
5. GET /orders/{orderId} sem auth retorna 401
6a. POST /test sem API Key retorna 403
6. test_controller publish_event
7. test_controller upload_file
8. test_controller list_files
9. Frontend S3 accessibility
10. CloudWatch Log Retention (14 dias)
11. DLQ Alarms existem
12. Reserved Concurrency
13. DynamoDB Audit Table TTL
14. test_controller rejeita detailType invalido
15. Resource Policy structural validation
16. Customer Register, Login, Me
17. Duplicate register retorna 409
18. Login com senha errada retorna 401
19. GET /catalog retorna cursos disponiveis
20. GET /catalog/{cursoId} retorna curso ou 404
21. GET /orders lista pedidos do cliente autenticado
22. GET /orders/{orderId} valida ownership
23. POST /orders/{orderId}/cancel autenticado
24. PATCH /orders/{orderId} autenticado
25. Frontend e QA Dashboard acessiveis
