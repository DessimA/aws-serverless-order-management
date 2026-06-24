# Lambda `pre_validator` (`src/pre_validator/index.py`)

## Finalidade

Ponto de entrada síncrono para pedidos via API Gateway. Valida campos obrigatórios (`pedidoId` e `clienteId`) e encaminha para a fila SQS FIFO de validação.

## Comportamento

1. Recebe requisição HTTP do API Gateway (integração AWS_PROXY).
2. Faz parse do JSON do corpo da requisição.
3. Valida presença de `pedidoId` e `clienteId` (retorna 400 se ausentes).
4. Envia mensagem para SQS FIFO com:
   - `MessageGroupId = pedidoId` (garante ordenação por pedido).
   - `MessageDeduplicationId = uuid4` (cada requisição e única; a dedup de negócios e feita no DynamoDB).
5. Retorna 200 com o `pedidoId` aceito.

## Ambiente

| Variável | Descrição |
|----------|-----------|
| `SQS_QUEUE_URL` | URL da fila SQS FIFO de validação |

