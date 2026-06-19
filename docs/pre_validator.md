# Lambda `pre_validator` (`src/pre_validator/index.py`)

## Finalidade

Ponto de entrada sincrono para pedidos via API Gateway. Valida campos obrigatorios (`pedidoId` e `clienteId`) e encaminha para a fila SQS FIFO de validacao.

## Comportamento

1. Recebe requisicao HTTP do API Gateway (integracao AWS_PROXY).
2. Faz parse do JSON do corpo da requisicao.
3. Valida presenca de `pedidoId` e `clienteId` (retorna 400 se ausentes).
4. Envia mensagem para SQS FIFO com:
   - `MessageGroupId = pedidoId` (garante ordenacao por pedido).
   - `MessageDeduplicationId = uuid4` (cada requisicao e unica; a dedup de negocios e feita no DynamoDB).
5. Retorna 200 com o `pedidoId` aceito.

## Ambiente

| Variavel | Descricao |
|----------|-----------|
| `SQS_QUEUE_URL` | URL da fila SQS FIFO de validacao |

## Mudancas recentes

- `MessageDeduplicationId` alterado de `str(order_id)` para `str(uuid.uuid4())`.
- Respostas HTTP agora usam `common.http` em vez de headers inline.
