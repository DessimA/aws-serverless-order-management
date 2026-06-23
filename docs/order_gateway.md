# Lambda `order_gateway` (`src/order_gateway/index.py`)

## Finalidade

Gateway de pedidos autenticado. Ponto de entrada de produção para leitura e ciclo de vida de pedidos (substitui o `test_controller` no fluxo de usuário final). Todos os handlers validam JWT antes de executar qualquer lógica de negócio.

## Comportamento

### `GET /orders` (list_handler)
Retorna lista de pedidos do cliente autenticado via GSI `clientId-index`.

| Cenário | HTTP | Resposta |
|---------|------|----------|
| Token válido, pedidos existentes | 200 | `{"orders": [...], "count": N}` |
| Token válido, nenhum pedido | 200 | `{"orders": [], "count": 0}` |
| Sem token ou inválido | 401 | `{"error": "Missing or invalid Authorization header"}` |

### `GET /orders/{orderId}` (get_handler)
Retorna pedido específico, apenas se pertencer ao cliente autenticado.

| Cenário | HTTP | Resposta |
|---------|------|----------|
| Pedido existe e e do cliente | 200 | Item completo |
| Pedido não existe | 404 | `{"error": "Order not found"}` |
| Pedido existe mas e de outro cliente | 404 | `{"error": "Order not found"}` (mesma mensagem) |
| Sem token ou inválido | 401 | `{"error": "..."}` |

### `POST /orders/{orderId}/cancel` (cancel_handler)
Publica evento `OrderCancelled` no EventBridge (fluxo assíncrono, processado por `lifecycle_ops`).

| Cenário | HTTP | Resposta |
|---------|------|----------|
| Sucesso | 202 | `{"status": "Cancellation requested", "orderId": "..."}` |
| Pedido ja cancelado | 409 | `{"error": "Order is already cancelled"}` |
| Pedido de outro cliente | 404 | `{"error": "Order not found"}` |
| EventBridge falhou | 500 | `{"error": "Failed to publish cancellation event"}` |

### `PATCH /orders/{orderId}` (update_handler)
Publica evento `OrderUpdated` no EventBridge com `novosItens`.

| Cenário | HTTP | Resposta |
|---------|------|----------|
| Sucesso | 202 | `{"status": "Update requested", "orderId": "..."}` |
| Pedido cancelado | 409 | `{"error": "Cannot update a cancelled order"}` |
| `novosItens` ausente/vazio | 400 | `{"error": "novosItens is required and must be a non-empty array"}` |
| Pedido de outro cliente | 404 | `{"error": "Order not found"}` |

## Ambiente

| Variável | Descrição |
|----------|-----------|
| `DYNAMODB_TABLE` | Nome da tabela order-production-data-* |
| `JWT_SECRET` | Segredo para validação de tokens JWT |
| `EVENT_BUS_NAME` | Nome do EventBridge custom bus para eventos de ciclo de vida |

## Decisões de design

### Autenticação na Lambda, não no API Gateway

O API Gateway continua com `authorization-type: NONE`. A validação do JWT ocorre dentro da Lambda. Motivo: a conta de laboratório não tem Cognito nem Lambda Authorizer. Um Lambda Authorizer reduziria o custo de invocação (bloqueio antes da Lambda de negócio), mas adiciona complexidade de deploy e exige outra Lambda com seu próprio zip e permissões. A diferença de custo e irrelevante para este cenário educacional.

### Cancel e update retornam 202, não 200

A operação e assíncrona. A Lambda publica um evento no EventBridge e retorna imediatamente. O estado real do pedido muda quando o `lifecycle_ops` processa o evento. Retornar 202 sinaliza que a requisição foi aceita para processamento, mas o resultado final não esta disponível na resposta.

### 404 genérico para pedido inexistente ou de outro cliente

Nao revelar se um pedido existe ou não quando o cliente não e o dono. Um atacante não consegue distinguir entre "este orderId nunca existiu" e "este orderId existe mas não e seu". Ambos retornam 404 com a mesma mensagem.

### Ponte clienteId / clientId

O JWT contem `clienteId` (convenção da API de identidade). O DynamoDB persiste como `clientId` (convenção do `order_processor`, que faz `str(order_detail.get('clienteId'))` ao criar o item). O `order_gateway` usa o valor de `clienteId` do JWT como argumento de busca no campo `clientId` da tabela.

### test_controller permanece como ferramenta de QA

O `test_controller` (POST /test) continua existindo como ferramenta interna de QA, permitindo que testadores publiquem eventos diretamente no EventBridge sem passar pelo fluxo de autenticação JWT. Nao e substituído porque:
- Testes de integração (Tests 6-8) dependem dele.
- Permite debug de fluxos de ciclo de vida sem depender do gateway.
- E protegido por API Key e Usage Plan.

## Fluxos

```mermaid
sequenceDiagram
    participant Client
    participant API as API Gateway
    participant Gateway as order_gateway
    participant DDB as DynamoDB
    participant EB as EventBridge
    participant LC as lifecycle_ops

    Note over Client,LC: GET /orders (lista do cliente)
    Client->>API: GET /orders (Authorization: Bearer JWT)
    API->>Gateway: evento
    Gateway->>Gateway: _require_auth → clienteId
    Gateway->>DDB: query GSI clientId-index
    DDB-->>Gateway: pedidos do cliente
    Gateway-->>API: 200 {"orders": [...], "count": N}
    API-->>Client: JSON

    Note over Client,LC: GET /orders/{id} (dono)
    Client->>API: GET /orders/{id} (Authorization: Bearer JWT)
    API->>Gateway: evento
    Gateway->>DDB: get_item
    DDB-->>Gateway: Item (ou vazio)
    Gateway->>Gateway: valida clientId
    Gateway-->>API: 200 (dono) ou 404 (outro)
    API-->>Client: JSON

    Note over Client,LC: POST /orders/{id}/cancel
    Client->>API: POST /orders/{id}/cancel (Authorization: Bearer JWT)
    API->>Gateway: evento
    Gateway->>DDB: get_item + valida dono
    Gateway->>Gateway: verifica se ja CANCELLED
    Gateway->>EB: put_events (OrderCancelled)
    EB->>LC: event
    LC->>DDB: status = CANCELLED
    Gateway-->>API: 202 {"status": "Cancellation requested"}
    API-->>Client: JSON

    Note over Client,LC: PATCH /orders/{id}
    Client->>API: PATCH /orders/{id} (Authorization: Bearer JWT)
    API->>Gateway: evento
    Gateway->>DDB: get_item + valida dono
    Gateway->>Gateway: verifica se CANCELLED
    Gateway->>EB: put_events (OrderUpdated + novosItens)
    EB->>LC: event
    LC->>DDB: items = novosItens, status = UPDATED
    Gateway-->>API: 202 {"status": "Update requested"}
    API-->>Client: JSON
```
