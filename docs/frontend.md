# Frontend

## Finalidade

Dois frontends servidos no mesmo bucket S3 Static Website:

- **`index.html`** / **`app.js`**: Produto para usuario final (CloudCert). Vem com autenticacao JWT, catalogo de cursos, meus pedidos, cancelamento e atualizacao.

- **`qa.html`** / **`qa.js`**: Painel de QA interno, preservado das rodadas anteriores. Usado para validacao manual e automatizada dos fluxos do pipeline de deploy.

## Estrutura de arquivos

| Arquivo | Papel |
|---------|-------|
| `frontend/index.html` | Pagina principal do produto (CloudCert). Estrutura com view de auth e view do app. |
| `frontend/app.js` | Logica do produto: autenticacao, catalogo, pedidos, ciclo de vida. |
| `frontend/qa.html` | Painel de QA interno (copiado do index.html original da Rodada 10). |
| `frontend/qa.js` | Logica do painel de QA (copiado do app.js original da Rodada 10). |
| `frontend/style.css` | Estilos compartilhados entre produto e QA. |
| `frontend/config.template.js` | Template com placeholders processado pelo deploy. |

## Gestao de estado

Duas chaves no `localStorage`:

- `oms_token`: string do JWT emitido por `POST /customers/login`.
- `oms_user`: objeto JSON com `clienteId` e `email` do usuario logado.

Ao carregar a pagina, o frontend verifica se `oms_token` existe e chama `GET /customers/me` com o token:

- Se 200: renderiza a view autenticada.
- Se 401 ou falhar: limpa `localStorage` e renderiza a view de autenticacao.

O `catalogCache` e um array em memoria que armazena o resultado de `GET /catalog` para evitar refetch ao trocar filtros.

## Fluxo de autenticacao

```mermaid
sequenceDiagram
    participant U as Usuario
    participant F as Frontend
    participant API as API Gateway
    participant A as customer-auth Lambda

    U->>F: Abre index.html
    F->>F: init(): ler localStorage
    alt token existe
        F->>API: GET /customers/me (Bearer token)
        API->>A: invoca Lambda
        A-->>API: 200 { clienteId, email }
        API-->>F: 200
        F->>F: showApp() + loadCatalog()
    else token ausente
        F->>F: showAuth()
    end

    U->>F: Preenche email + senha + clica Entrar
    F->>API: POST /customers/login { email, password }
    API->>A: invoca Lambda
    A-->>API: 200 { token, clienteId }
    API-->>F: 200
    F->>F: localStorage.setItem + showApp()

    U->>F: Clica Sair
    F->>F: localStorage.clear() + showAuth()
```

## Fluxo de compra

```mermaid
sequenceDiagram
    participant U as Usuario
    participant F as Frontend
    participant API as API Gateway
    participant P as pre-validator Lambda

    U->>F: Navega no catalogo, clica Comprar
    F->>F: buyCourse(): monta payload com clienteId do JWT
    F->>API: POST /orders { pedidoId, clienteId, itens }
    API->>P: invoca Lambda (sem auth)
    P-->>API: 200 Order accepted
    API-->>F: 200
    F->>F: alert("Pedido realizado") + showView("orders")
    F->>F: loadOrders()
```

## Fluxo de ciclo de vida

```mermaid
sequenceDiagram
    participant U as Usuario
    participant F as Frontend
    participant API as API Gateway
    participant G as order-gateway Lambda
    participant EB as EventBridge

    U->>F: Abre Meus Pedidos
    F->>API: GET /orders (Bearer token)
    API->>G: invoca (list_handler)
    G-->>API: 200 { orders }
    API-->>F: 200

    U->>F: Clica Ver Detalhes
    F->>API: GET /orders/{orderId} (Bearer token)
    API->>G: invoca (get_handler)
    G-->>API: 200 { order }
    API-->>F: 200

    U->>F: Clica Cancelar Pedido
    F->>API: POST /orders/{orderId}/cancel (Bearer token)
    API->>G: invoca (cancel_handler)
    G->>EB: PutEvents OrderCancelled
    G-->>API: 202 { status: "Cancellation requested" }
    API-->>F: 202

    Note over F: Feedback: "Cancelamento solicitado. Atualizando em 3s..."
    F->>F: setTimeout -> viewOrderDetail()
```

## Decisoes de design

### Injecao de clienteId no POST /orders

O `POST /orders` nao exige autenticacao no backend (pre-validator nao valida JWT). O frontend injeta o `clienteId` do objeto `currentUser` (obtido do JWT) como campo `clienteId` do payload. Isso evita alterar o pre-validator e mantem a compatibilidade com o fluxo original.

### Feedback assincrono para cancelamento e atualizacao

Cancelamento e atualizacao sao operacoes assincronas via EventBridge. O frontend retorna 202 e exibe "solicitado, aguarde" porque a mudanca de estado so ocorre apos o lifecycle-processor processar o evento. Apos 3 segundos o frontend faz refresh automatico do detalhe.

### Preservacao do QA dashboard

O QA dashboard foi preservado em vez de removido porque e usado pelo `validate-flow.sh` (Testes 6, 7, 8) e serve como ferramenta de validacao do pipeline de deploy. Registrar, logar e testar o fluxo completo no QA dashboard continua funcionando normalmente em `/qa.html`.

### localStorage em vez de HttpOnly cookies

Nao ha servidor Node/backend para SSR. `localStorage` e adequado para o escopo de portfolio. Em producao, cookies HttpOnly seriam preferiveis para mitigar XSS, mas a ausencia de um backend de renderizacao inviabiliza essa abordagem sem um proxy reverso dedicado.
