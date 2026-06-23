# Lambda `read_order` (`src/read_order/index.py`)

## Finalidade

Endpoint de consulta de pedidos (`GET /orders/{orderId}`). Integrada ao API Gateway, consulta o DynamoDB e retorna o pedido completo ou 404.

## Comportamento

1. Requisições OPTIONS são tratadas pela integração MOCK do API Gateway (setup_api_cors) antes de chegar a Lambda.
2. Extrai `orderId` dos path parameters, tratando `null` com `(params or {})`.
3. Consulta DynamoDB via `GetItem`.
4. Retorna 200 com o item, ou 404 se não encontrado.
5. Erros `ClientError` são logados com contexto e retornam 500.

## Ambiente

| Variável | Descrição |
|----------|-----------|
| `DYNAMODB_TABLE` | Nome da tabela de produção |

## Mudancas recentes

- PathParameters null tratado com `event.get("pathParameters") or {}`.
- Logging adicionado no `except ClientError`.
- Uso de `common.http.api_response()` e `error_response()`.
