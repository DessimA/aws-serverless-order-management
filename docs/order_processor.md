# Lambda `order_processor` (`src/order_processor/index.py`)

## Finalidade

Persiste pedidos validados na tabela DynamoDB `order-production-data`. E acionada por uma fila SQS FIFO (`order-persister-queue`) que recebe eventos do EventBridge com `detail-type: OrderValidated`.

## Comportamento

1. Extrai o envelope SQS e o detail do evento usando `common.sqs.parse_body()` e `common.sqs.parse_detail()`.
2. Valida presenca de `pedidoId` (registros sem pedidoId sao ignorados).
3. Persiste o pedido com `ConditionExpression: attribute_not_exists(orderId)` para garantir idempotencia.
4. Se o pedido ja existe (`ConditionalCheckFailedException`):
   - Loga o evento e publica alerta via SNS.
   - Nao relanca a excecao (comportamento intencional de idempotencia).
5. Erros de DynamoDB ou outros sao capturados e adicionados a `batchItemFailures`.
6. Retorna `{"batchItemFailures": [...]}` para que apenas mensagens com erro sejam reprocessadas.

## Ambiente

| Variavel | Descricao |
|----------|-----------|
| `DYNAMODB_TABLE` | Nome da tabela de producao |
| `SNS_TOPIC_ARN` | ARN do topico SNS para alertas de duplicidade |

## Mudancas recentes

- Substituido `json.loads()` manual por `parse_detail()` (corrige TypeError com detail como dict).
- Adicionado `SNS_TOPIC_ARN` e `publish_error()` para alertas de duplicata.
- Alterado retorno de `{'statusCode': 200}` para `{"batchItemFailures": [...]}`.
