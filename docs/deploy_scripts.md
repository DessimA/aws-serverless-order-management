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

## `validate-flow.sh`

- Adicionado Teste 1b: Duplicidade - reenvia o mesmo pedidoId e verifica que:
  - A API aceita (SQS dedup bypassed por uuid4).
  - O DynamoDB mantem o registro original (ConditionExpression).
- Adicionado SNS_TOPIC_ARN nas variaveis para verificacao de alertas.
