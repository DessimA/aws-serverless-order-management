# Lambda `lifecycle_ops` (`src/lifecycle_ops/index.py`)

## Finalidade

Gerencia operacoes de ciclo de vida de pedidos: cancelamento e atualizacao de itens. Exposta como dois handlers (`cancel_handler` e `update_handler`), cada um acionado por sua propria fila SQS FIFO.

## Comportamento

1. Extrai o detail do evento usando `common.sqs.parse_detail()`.
2. Para cancelamento: altera status para `CANCELLED` com `ConditionExpression: attribute_exists(orderId)`.
3. Para atualizacao: substitui os itens e altera status para `UPDATED` com `ConditionExpression: attribute_exists(orderId)`.
4. Se o pedido nao existe (`ConditionalCheckFailedException`):
   - Loga o evento e publica alerta via SNS.
   - Nao relanca (comportamento intencional de idempotencia).
5. Erros de DynamoDB sao adicionados a `batchItemFailures`.
6. Retorna `{"batchItemFailures": [...]}`.

## Ambiente

| Variavel | Descricao |
|----------|-----------|
| `DYNAMODB_TABLE` | Nome da tabela de producao |
| `SNS_TOPIC_ARN` | ARN do topico SNS para alertas de pedido inexistente |

## Mudancas recentes

- Substituido `json.loads(json.loads(...))` por `parse_detail()`.
- Adicionado `SNS_TOPIC_ARN` e `publish_error()` para alertas de pedido inexistente.
- Alterado retorno para `{"batchItemFailures": [...]}`.
