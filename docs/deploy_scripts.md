# Scripts de Deploy (`scripts/`)

Infraestrutura como Codigo (IaC) via AWS CLI. Cada script provisiona um conjunto de recursos de forma idempotente (padrao check-before-create).

## `lib.sh`

Biblioteca compartilhada com funcoes utilitarias:

| Funcao | Descricao |
|--------|-----------|
| `validate_env` | Valida variaveis de ambiente obrigatorias |
| `validate_resource_suffix` | Valida formato `[a-z0-9-]` do sufixo |
| `ensure_iam_lambda_role` | Cria IAM Role com trust policy para Lambda |
| `ensure_lambda_function` | Cria ou atualiza funcao Lambda com reserved concurrency e log retention |
| `ensure_sqs_queue` | Cria fila SQS com DLQ, VisibilityTimeout, atributos |
| `ensure_event_source_mapping` | Cria/atualiza mapping SQS-Lambda com ReportBatchItemFailures |
| `ensure_dlq_alarm` | Cria CloudWatch Alarm para DLQ com acao SNS |
| `ensure_api_resource_policy` | Aplica Resource Policy no API Gateway (Allow geral + Deny condicional) |
| `ensure_usage_plan_with_api_key` | Cria Usage Plan com throttle/quota e API Key |
| `ensure_jwt_secret` | Gera ou le segredo JWT de arquivo local |
| `validate_sqs_queue` | Valida VisibilityTimeout e ContentBasedDeduplication |
| `validate_lambda_config` | Verifica timeout=60 e variaveis de ambiente obrigatorias |
| `validate_eventbridge_target` | Valida target do EventBridge |
| `setup_api_cors` | Configura CORS no metodo OPTIONS |
| `poll_resource` | Polling generico com timeout |
| `get_endpoint_url` | Monta URL de endpoint (API Gateway ou S3) |
| `load_env` | Carrega variaveis do arquivo .env |
## `deploy-api-flow.sh`

Provisiona: EventBus, SNS Topic, filas FIFO (validation-buffer, validation-dlq), pre-validator Lambda, validator Lambda, API Gateway com recurso /orders, Request Validator com JSON Schema.

## `deploy-order-processor.sh`

Provisiona: order-persister Lambda, fila persister-queue Standard com DLQ, EventBridge target, IAM Role com permissoes DynamoDB e SNS.

## `deploy-lifecycle-ops.sh`

Provisiona: lifecycle_ops Lambda (handlers cancel e update), filas cancel-order-queue e update-order-queue Standard com DLQs, EventBridge targets, IAM Role com permissoes DynamoDB e SNS.

## `deploy-s3-flow.sh`

Provisiona: S3 bucket de dados, fila s3-batch-queue Standard com DLQ (notificacao S3 direta), batch-processor Lambda, tabela de auditoria DynamoDB com TTL 90 dias, IAM Role.

## `deploy-customer-auth.sh`

Provisiona: tabela DynamoDB customer-data, customer-auth Lambda, recursos /customers/register, /customers/login, /customers/me no API Gateway, JWT secret local.

## `deploy-order-gateway.sh`

Provisiona: GSI clientId-index na tabela de producao, order-gateway Lambda, endpoints autenticados GET/PATCH /orders/{orderId}, POST /orders/{orderId}/cancel, GET /orders. Remove permissao antiga do order-reader (substituido).

Define internamente a funcao local `deploy_gateway_endpoint` para configurar metodo, integracao, CORS e permissao Lambda em um unico bloco reutilizavel dentro do script.

## `deploy-catalog.sh`

Provisiona: tabela DynamoDB course-catalog, catalog-reader Lambda, recursos /catalog e /catalog/{cursoId} no API Gateway.

## `seed-catalog.sh`

Faz upsert de 11 itens no catalogo (cursos AWS, Azure, GCP e vouchers AWS). Um item (GCP-PCA-001) tem disponivel=false para teste de filtro.

## `deploy-frontend.sh`

Provisiona: S3 bucket para static website, test-controller Lambda, recurso /test no API Gateway com API Key, Usage Plan, Resource Policy. Sincroniza index.html, qa.html, style.css, app.js, qa.js, config.js com endpoints injetados via sed.

## `validate-flow.sh`

Executa deploy completo e 25 testes:
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
