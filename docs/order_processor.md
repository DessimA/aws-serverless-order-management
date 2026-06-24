# Lambda `order_processor` (`src/order_processor/index.py`)

## Finalidade

Persiste pedidos validados na tabela DynamoDB `order-production-data`. E acionada por uma fila SQS FIFO (`order-persister-queue`) que recebe eventos do EventBridge com `detail-type: OrderValidated`.

## Comportamento

1. Extrai o envelope SQS e o detail do evento usando `common.sqs.parse_body()` e `common.sqs.parse_detail()`.
2. Valida presença de `pedidoId` (registros sem pedidoId são ignorados).
3. Persiste o pedido com `ConditionExpression: attribute_not_exists(orderId)` para garantir idempotência.
4. Se o pedido ja existe (`ConditionalCheckFailedException`):
   - Loga o evento e publica alerta via SNS.
   - Nao relanca a exceção (comportamento intencional de idempotência).
5. Erros de DynamoDB ou outros são capturados e adicionados a `batchItemFailures`.
6. Retorna `{"batchItemFailures": [...]}` para que apenas mensagens com erro sejam reprocessadas.

## Ambiente

| Variável | Descrição |
|----------|-----------|
| `DYNAMODB_TABLE` | Nome da tabela de produção |
| `SNS_TOPIC_ARN` | ARN do topico SNS para alertas de duplicidade |

