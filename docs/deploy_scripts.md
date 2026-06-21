# Scripts de Deploy (`scripts/`)

## Finalidade

Infraestrutura como Codigo (IaC) via AWS CLI. Cada script provisiona um conjunto de recursos de forma idempotente.

## `lib.sh`

Biblioteca compartilhada com 20+ funcoes utilitarias.

### Mudancas recentes

| Funcao | Mudanca |
|--------|---------|
| `validate_env()` | Agora chama automaticamente `validate_resource_suffix()` quando `RESOURCE_SUFFIX` esta presente. |
| `validate_resource_suffix()` | Nova funcao: valida formato `[a-z0-9-]` do sufixo, falhando cedo se invalido. |
| `ensure_sqs_queue()` | `VisibilityTimeout` agora usa a variavel `$VISIBILITY_TIMEOUT` (padrao 360s). |
| `validate_sqs_queue()` | Validacao de VisibilityTimeout usa a mesma variavel. |
| `ensure_event_source_mapping()` | Cria/atualiza mapeamento com `--function-response-types ReportBatchItemFailures`. |

## `deploy-order-processor.sh`

- Adicionado `SNS_TOPIC_ARN` nas variaveis de ambiente da Lambda.
- Adicionada permissao `sns:Publish` na role IAM.
- `validate_lambda_config` agora valida `SNS_TOPIC_ARN`.

## `deploy-lifecycle-ops.sh`

- Resolucao do `SNS_TOPIC_ARN` via AWS CLI dentro da funcao `deploy_lifecycle_handler`.
- Adicionada permissao `sns:Publish` para alertas de pedido inexistente.
- `validate_lambda_config` agora valida `SNS_TOPIC_ARN`.

## `lib.sh` (Rodada 5)

| Funcao | Mudanca |
|--------|---------|
| `ensure_lambda_function()` | Agora aceita 7o parametro `reserved_concurrency`. Aplica `put-function-concurrency` quando definido. Tambem adiciona retention policy de 14 dias no log group. |
| `ensure_dlq_alarm()` | Nova funcao: cria CloudWatch Alarm monitorando `ApproximateNumberOfMessagesVisible` para DLQ, com acao SNS. Idempotente (checa existencia antes de criar). |
| `ensure_api_resource_policy()` | Nova funcao: aplica Resource Policy no API Gateway restringindo por IP quando `ALLOWED_SOURCE_IP` esta definido. |
| `ensure_usage_plan_with_api_key()` | Nova funcao: cria Usage Plan com throttle (rateLimit=5, burstLimit=10) e quota (1000 req/dia), cria API Key e associa. |

## `deploy-api-flow.sh` (Rodada 5)

- Resource Policy aplicada no REST API quando `ALLOWED_SOURCE_IP` esta definido.
- Request Validator (JSON Schema) criado para metodo POST /orders, validando presenca de `pedidoId` e `clienteId` antes de invocar a Lambda.

## `deploy-s3-flow.sh` (Rodada 5)

- TTL habilitado na tabela de auditoria DynamoDB (`order-batch-audit-*`) com `expiresAt` em 90 dias.
- DLQ alarm criado para `order-s3-batch-dlq-*`.

## `deploy-order-processor.sh` (Rodada 5)

- DLQ alarm criado para `order-persister-dlq-*`.

## `deploy-lifecycle-ops.sh` (Rodada 5)

- DLQ alarm criado para `cancel-order-dlq-*` e `update-order-dlq-*`.

## `deploy-frontend.sh` (Rodada 5)

- API Key obrigatoria no metodo POST /test (`--api-key-required`).
- Usage Plan criado com throttle e quota, associado ao stage prod.
- Frontend envia header `x-api-key` em todas as chamadas a /test.

## `validate-flow.sh`

- Adicionado Teste 1b: Duplicidade - reenvia o mesmo pedidoId e verifica que:
  - A API aceita (SQS dedup bypassed por uuid4).
  - O DynamoDB mantem o registro original (ConditionExpression).
- Adicionado SNS_TOPIC_ARN nas variaveis para verificacao de alertas.
- Adicionado Teste 6a: POST /test sem API Key retorna 403.
- Adicionado Teste 10: Verificacao de retentionInDays=14 nos log groups.
- Adicionado Teste 11: Verificacao de existencia dos 5 DLQ alarms.
- Adicionado Teste 12: Verificacao de ReservedConcurrentExecutions configurado.
- Adicionado Teste 13: Verificacao de TimeToLiveStatus=ENABLED na tabela de auditoria.

## Notas de validacao manual

## `scripts/lib.sh` (Rodada 6)

- `ensure_api_resource_policy()`: Resource ARN restrito a `*/*/POST/test` (antes cobria toda a API). Movido de `deploy-api-flow.sh` para `deploy-frontend.sh`.

## `scripts/validate-flow.sh` (Rodada 6)

- Teste 14: Test Controller detailType Allowlist - envia detailType invalido (`OrderCreated`) e verifica retorno 400.

### Resource Policy (Item 2)
Para testar a restricao de IP em /test:
1. Defina `ALLOWED_SOURCE_IP=SEU_IP/32` no .env e execute o deploy.
2. De outro IP (ou remova o header), tente chamar POST /test.
3. A resposta deve ser 403 Forbidden.
4. Com `ALLOWED_SOURCE_IP` vazio, o comportamento atual e mantido (sem restricao).
Nota: Nao e possivel automatizar esse teste via validate-flow.sh sem trocar de IP de origem.
