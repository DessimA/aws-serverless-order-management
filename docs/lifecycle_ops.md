# Lambda `lifecycle_ops` (`src/lifecycle_ops/index.py`)

## Finalidade

Gerência operações de ciclo de vida de pedidos: cancelamento e atualização de itens. Exposta como dois handlers (`cancel_handler` e `update_handler`), cada um acionado por sua própria fila SQS FIFO.

## Comportamento

1. Extrai o detail do evento usando `common.sqs.parse_detail()`.
2. Para cancelamento: altera status para `CANCELLED` com `ConditionExpression: attribute_exists(orderId)`.
3. Para atualização: substitui os itens e altera status para `UPDATED` com `ConditionExpression: attribute_exists(orderId)`.
4. Se o pedido não existe (`ConditionalCheckFailedException`):
    - Loga o evento e publica alerta via SNS usando `common.sns.publish_error()`.
    - Nao relanca (comportamento intencional de idempotência).
5. Erros de DynamoDB são adicionados a `batchItemFailures`.
6. Retorna `{"batchItemFailures": [...]}`.

## Ambiente

| Variável | Descrição |
|----------|-----------|
| `DYNAMODB_TABLE` | Nome da tabela de produção |
| `SNS_TOPIC_ARN` | ARN do topico SNS para alertas de pedido inexistente |

