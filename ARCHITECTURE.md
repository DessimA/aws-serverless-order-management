# Decisoes de Arquitetura

## Sumario

1.  [Por que Event-Driven Architecture?](#1-por-que-event-driven-architecture)
2.  [Resiliencia: DLQ, batchItemFailures e VisibilityTimeout](#2-resiliencia-dlq-batchitemfailures-e-visibilitytimeout)
3.  [Idempotencia: ConditionExpression vs deduplicacao na fila](#3-idempotencia-conditionexpression-vs-deduplicacao-na-fila)
4.  [Seguranca sem WAF, Cognito e KMS](#4-seguranca-sem-waf-cognito-e-kms)
5.  [Observabilidade sem X-Ray](#5-observabilidade-sem-x-ray)
6.  [Controle de custo em conta de laboratorio](#6-controle-de-custo-em-conta-de-laboratorio)
7.  [IaC com shell scripts: escolha e limites](#7-iac-com-shell-scripts-escolha-e-limites)
8.  [FIFO vs Standard: quando usar cada um](#8-fifo-vs-standard-quando-usar-cada-um)
9.  [Frontend: localStorage, JWT e operacoes assincronas](#9-frontend-localstorage-jwt-e-operacoes-assincronas)
10. [O que seria diferente em producao real](#10-o-que-seria-diferente-em-producao-real)

---

## 1. Por que Event-Driven Architecture?

### Diagrama comparativo

O fluxo abaixo mostra a diferenca entre uma abordagem sincrona (sem barramento de eventos) e a arquitetura atual com EventBridge como orquestrador central.

```mermaid
sequenceDiagram
    participant C as Cliente
    participant GW as API Gateway
    participant PRE as pre_validator
    participant PROC as order_processor
    participant DDB as DynamoDB

    rect rgb(200, 100, 100)
    Note over C,DDB: SEM EDA (sincrono)
    C->>GW: POST /orders
    GW->>PRE: proxy
    PRE->>PROC: chamada direta
    PROC->>DDB: put_item
    DDB-->>PROC: ok
    PROC-->>PRE: ok
    PRE-->>C: 200
    Note over C: Cliente espera todo o<br/>processamento antes<br/>de receber resposta
    end
```

```mermaid
sequenceDiagram
    participant C as Cliente
    participant GW as API Gateway
    participant PRE as pre_validator
    participant FIFO as SQS FIFO
    participant VAL as order_validator
    participant EB as EventBridge
    participant SQS as SQS Persister
    participant PROC as order_processor
    participant DDB as DynamoDB
    participant SNS as SNS

    rect rgb(100, 200, 100)
    Note over C,DDB: COM EDA (arquitetura atual)
    C->>GW: POST /orders
    GW->>PRE: proxy
    PRE->>FIFO: envia para buffer
    PRE-->>C: 202 Accepted
    Note over C: Cliente recebe resposta<br/>imediatamente, sem<br/>esperar processamento
    FIFO->>VAL: mensagem
    VAL->>EB: OrderValidated
    EB->>SQS: regra roteia para fila
    SQS->>PROC: record
    PROC->>DDB: put_item
    PROC->>SNS: alerta se duplicata
    end
```

### Beneficios da abordagem EDA

- **Desacoplamento:** `pre_validator` nao conhece `order_processor`. A resposta 202 e retornada antes do pedido ser persistido.
- **Resiliencia a falhas:** Se o DynamoDB estiver indisponivel, a mensagem permanece na fila SQS com VisibilityTimeout, aguardando nova tentativa. Nenhum dado e perdido.
- **Escalabilidade independente:** Cada consumidor pode escalar separadamente (reserved_concurrency=5 para processamento, 10 para leitura).

### Trade-off aceito

Complexidade de observabilidade: um pedido atravessa 4+ Lambdas (pre_validator, order_validator, order_processor, lifecycle_ops). Rastrear uma unica transacao exige correlacao manual por `pedidoId` via CloudWatch Logs Insights. A funcao `log_event()` em `src/common/utils.py` produz JSON estruturado com `pedidoId` para permitir essa correlacao.

---

## 2. Resiliencia: DLQ, batchItemFailures e VisibilityTimeout

### DLQ e maxReceiveCount

Cada fila SQS tem uma Dead Letter Queue (DLQ) associada com `maxReceiveCount=3`.

```mermaid
flowchart TD
    A["Fila Principal"] -->|"1a tentativa<br/>(processamento normal)"| B["Lambda"]
    B -->|"Sucesso"| C["Mensagem deletada"]
    B -->|"Erro (batchItemFailures)"| D["Visibilidade timeout<br/>Mensagem reaparece"]
    D -->|"2a tentativa"| B
    D -->|"3a tentativa (maxReceiveCount)"| E["DLQ"]
    E --> F["CloudWatch Alarm<br/>ApproximateNumberOfMessagesVisible >= 1"]
    F --> G["Alerta SNS (email)"]
```

Cinco DLQs ativas: `validation-dlq`, `persister-dlq`, `cancel-dlq`, `update-dlq`, `s3-batch-dlq`. Cada uma tem um CloudWatch Alarm exclusivo.

### batchItemFailures

Todas as 4 Lambdas acionadas por SQS implementam o padrao `batchItemFailures`:

```mermaid
sequenceDiagram
    participant SQS as SQS (lote)
    participant L as Lambda
    participant DDB as DynamoDB

    SQS->>L: Lote [msg1(ok), msg2(erro)]
    L->>L: Processa msg1
    L->>DDB: put_item (sucesso)
    L->>L: Processa msg2
    L->>DDB: put_item (falha)
    L-->>SQS: {"batchItemFailures": [{"itemIdentifier": "msg2_id"}]}
    Note over L: Apenas msg2 sera<br/>reenviada. msg1<br/>confirmada.
    SQS->>L: Reenvia apenas msg2
```

Retorno esperado: `{"batchItemFailures": [{"itemIdentifier": "messageId"}]}`. Sem a configuracao, uma unica falha derrubaria o lote inteiro de 5 mensagens.

### VisibilityTimeout

Formula: `VT > batch_size x lambda_timeout`. Configuracao: `VT=360s, batch_size=5, lambda_timeout=60s`. Calculo: `360 > 5 x 60 = 300`. Margem de 60s para propagacao de rede e overhead.

---

## 3. Idempotencia: ConditionExpression vs deduplicacao na fila

### Diagrama de duplicidade

```mermaid
sequenceDiagram
    participant APP as Frontend
    participant PRE as pre_validator
    participant FIFO as SQS FIFO
    participant VAL as order_validator
    participant EB as EventBridge
    participant SQS as SQS Persister
    participant PROC as order_processor
    participant DDB as DynamoDB
    participant SNS as SNS

    Note over APP: Primeiro envio (pedidoId=ORD-123)
    APP->>PRE: POST /orders
    PRE->>FIFO: MessageDeduplicationId=uuid4(novo)
    FIFO->>VAL: mensagem
    VAL->>EB: OrderValidated
    EB->>SQS: detail
    SQS->>PROC: record
    PROC->>DDB: put_item com<br/>ConditionExpression
    DDB-->>PROC: 200 (criado)

    Note over APP: Segundo envio (mesmo pedidoId=ORD-123)
    APP->>PRE: POST /orders
    PRE->>FIFO: MessageDeduplicationId=uuid4(novo)
    Note over FIFO: uuid4 unico, entao a<br/>mensagem passa pela fila
    FIFO->>VAL: mensagem
    VAL->>EB: OrderValidated
    EB->>SQS: detail
    SQS->>PROC: record
    PROC->>DDB: put_item com<br/>ConditionExpression
    DDB-->>PROC: ConditionalCheckFailedException
    PROC->>SNS: Alerta "Duplicate Order"
    Note over DDB: Pedido NAO sobrescrito
```

### Por que nao usar MessageDeduplicationId baseado no pedidoId?

Em versoes iniciais, `MessageDeduplicationId = pedidoId`. Isso impedia que reenvios do mesmo pedido chegassem ao DynamoDB por 5 minutos (janela de deduplicacao do SQS FIFO). Um frontend que tentasse reenviar o mesmo pedido nao veria o alerta SNS, pois a mensagem nao passava da fila.

A correcao foi usar `MessageDeduplicationId = uuid4()` (sempre unico) e mover a responsabilidade de deduplicacao de negocio inteiramente para o DynamoDB:

| Aspecto | SQS FIFO | DynamoDB |
|---------|----------|----------|
| Janela | 5 minutos | Permanente |
| Efeito | Impede reenvio | Impede sobrescrita |
| Alerta | Nenhum | SNS com detalhes |

A `ConditionExpression: attribute_not_exists(orderId)` garante que mesmo com reenvios, o pedido original nunca e sobrescrito. Se o reenvio chegar ao `order_processor`, um alerta SNS e publicado.

---

## 4. Seguranca sem WAF, Cognito e KMS

### Tabela de compensacoes

| Requisito | Solucao padrao de producao | Solucao adotada (conta de laboratorio) |
|---|---|---|
| Autenticacao de usuario | Cognito User Pools | JWT HS256 manual com stdlib Python |
| Rotacao de segredo JWT | Secrets Manager | Arquivo `.jwt-secret` local (idempotente) |
| Restricao de IP no endpoint /test | WAF IP Set | API Gateway Resource Policy com `NotIpAddress` |
| Rate limiting | WAF Rate Rule | Usage Plan com throttle rateLimit=5, burstLimit=10 |
| Signing de requests entre servicos | IAM Roles + SigV4 | Lambda IAM Roles com least privilege |
| Isolamento de dados por cliente | Cognito groups + DynamoDB FK | GSI `clientId-index` + validacao ownership inline |

### JWT manual: decisoes de implementacao

O modulo `src/common/auth.py` implementa JWT HS256 sem dependencias externas:

- **Hash de senha:** PBKDF2-SHA256 com 200.000 iteracoes e salt de 16 bytes (`os.urandom`).
- **Criacao do JWT:** Header `{"alg":"HS256","typ":"JWT"}`, payload com `iat`/`exp`, assinatura HMAC-SHA256, codificacao base64url sem padding.
- **Validacao do JWT:** `hmac.compare_digest` previne timing attack. Expiracao checada por `time.time()`.
- **Ausencia de dependencias:** Nenhum `requirements.txt` ou camada Lambda. O empacotamento zip contem apenas o codigo do projeto.

### Isolamento de dados por cliente

O GSI `clientId-index` na tabela `order-production-data` permite listar pedidos por `clientId` com `KeyConditionExpression`, sem scan.

A Lambda `order_gateway` valida ownership em todas as operacoes:

```python
def _get_owned_order(table, order_id, client_id):
    result = table.get_item(Key={"orderId": order_id})
    item = result.get("Item")
    if not item or item.get("clientId") != client_id:
        return None  # retorna 404 - mesmo codigo para "nao encontrado" e "de outro cliente"
    return item
```

O retorno 404 generico previne information disclosure: um cliente nao consegue distinguir entre um pedido que nao existe e um pedido que existe mas pertence a outro cliente.

---

## 5. Observabilidade sem X-Ray

### Correlacao por pedidoId

```mermaid
sequenceDiagram
    participant PRE as pre_validator
    participant VAL as order_validator
    participant PROC as order_processor
    participant LC as lifecycle_ops
    participant CW as CloudWatch Logs

    PRE->>CW: {"stage":"pre_validator","pedidoId":"ORD-123",...}
    VAL->>CW: {"stage":"order_validator","pedidoId":"ORD-123",...}
    PROC->>CW: {"stage":"order_processor","pedidoId":"ORD-123",...}
    LC->>CW: {"stage":"lifecycle_ops","pedidoId":"ORD-123",...}

    Note over CW: Query CloudWatch Logs Insights:
    fields @timestamp, stage, pedidoId, message
    | filter pedidoId = "ORD-123"
    | sort @timestamp asc
```

A funcao `log_event(stage, pedido_id, message)` em `src/common/utils.py` produz JSON estruturado que permite queries de correlacao no CloudWatch Logs Insights.

### Por que nao X-Ray?

X-Ray nao esta disponivel na conta de laboratorio. Em producao, X-Ray com sampling ativo substituiria o log estruturado para rastreamento distribuido, mantendo o log estruturado apenas para auditoria de negocio.

### Logs de erro vs logs de sucesso

Logs de sucesso contem apenas `pedidoId` e estagio (sem payload completo). Logs de erro (blocos `except`) mantem detalhes completos do evento, pois ocorrem com baixa frequencia. Essa estrategia reduz custo de ingestao do CloudWatch.

---

## 6. Controle de custo em conta de laboratorio

### Decisoes e configuracoes

| Decisao | Impacto | Configuracao |
|---|---|---|
| Reserved Concurrency | Limita execucoes simultaneas | 5 por Lambda de processamento, 10 para read/catalog |
| Log retention | Elimina acumulo indefinido de logs | 14 dias em todos os log groups |
| DynamoDB PAY_PER_REQUEST | Sem custo de capacidade ociosa | Todas as tabelas |
| TTL na tabela de auditoria | Remove registros antigos automaticamente | 90 dias, campo `expiresAt` |
| S3 Static Website | Sem custo de servidor web | Frontend servido diretamente do S3 |
| Lambda timeout 60s | Evita cobranca por execucoes longas | Todas as funcoes |

### Reserved Concurrency como protecao de custo

O `reserved_concurrency` limita o numero maximo de execucoes simultaneas de cada Lambda. Nao se trata de otimizacao de performance, mas de protecao de custo em conta compartilhada de laboratorio. Sem WAF ou Usage Plan obrigatorio em todas as rotas, um volume alto de chamadas poderia gerar custo inesperado.

---

## 7. IaC com shell scripts: escolha e limites

### O que os scripts fazem

Cada script de deploy segue o padrao `ensure_*`: verifica se o recurso ja existe antes de criar (check-before-create). Exemplo de funcoes:

| Funcao | Comportamento |
|---|---|
| `ensure_lambda_function` | `aws lambda get-function` -> se existe, `update-function-code`; se nao, `create-function` |
| `ensure_sqs_queue` | `aws sqs get-queue-url` -> cria com DLQ, VisibilityTimeout, URL/ARN |
| `ensure_iam_lambda_role` | `aws iam get-role` -> cria com trust policy e inline permissions |
| `poll_resource` | Polling generico com timeout para aguardar recursos ficarem prontos |

### Comparacao com Terraform

| Aspecto | Shell + AWS CLI | Terraform |
|---|---|---|
| Preview de mudancas | Nenhum (sem plan) | `terraform plan` |
| Grafo de dependencias | Manual (ordem dos scripts) | Automatico |
| State management | Nenhum (idempotencia via check) | `terraform.tfstate` |
| Portabilidade multi-cloud | Nenhuma | Alta (providers) |
| Curva de aprendizado | Baixa (AWS CLI direto) | Media |
| Exposicao ao servico AWS | Alta (cada parametro explicito) | Baixa (abstraida pelo provider) |

### Por que shell scripts?

A escolha foi intencional para fins educacionais. Cada script expoe os parametros reais da API AWS. Por exemplo, ao configurar um target EventBridge para SQS FIFO, o script passa explicitamente `SqsParameters={"MessageGroupId":"..."}`, `ContentBasedDeduplication`, e a Resource-Based Policy da fila. Em um projeto de producao com equipe, Terraform ou CDK seriam preferidos pelo plan preview e state management.

---

## 8. FIFO vs Standard: quando usar cada um

### Mapa de filas no sistema

```mermaid
flowchart LR
    subgraph "Ingestao"
        PRE["pre_validator"]
        FIFO["order-validation-buffer<br/>(FIFO)"]
        R1["order-validation-dlq<br/>(FIFO DLQ)"]
        PRE --> FIFO
        FIFO --> R1
    end

    subgraph "Processamento (Standard)"
        PERSQ["order-persister-queue"]
        CANCELQ["cancel-order-queue"]
        UPDATEQ["update-order-queue"]
        S3Q["order-s3-batch-queue"]
    end

    subgraph "EventBridge"
        EB["orders-event-bus"]
        EB --> PERSQ
        EB --> CANCELQ
        EB --> UPDATEQ
    end

    subgraph "S3"
        S3["order-files-bucket"] --> S3Q
    end
```

### Tabela de tipos

| Fila | Tipo | Motivo |
|---|---|---|
| order-validation-buffer | FIFO | Ordenacao por pedido (MessageGroupId=pedidoId), ContentBasedDeduplication |
| order-validation-dlq | FIFO | DLQ de fila FIFO deve ser FIFO |
| order-persister-queue | Standard | Idempotencia garantida pelo DynamoDB, paralelismo desejado |
| cancel-order-queue | Standard | Idem |
| update-order-queue | Standard | Idem |
| order-s3-batch-queue | Standard | Notificacoes S3 nao garantem ordem, Standard e suficiente |

### O bug de Rodada 4

Inicialmente, as filas de processamento (persister, cancel, update) eram FIFO com `MessageGroupId` estatico. Isso forcava processamento sequencial: mesmo que dois pedidos fossem independentes, um precisava terminar para o outro comecar. Como a idempotencia ja era garantida pelo DynamoDB, nao havia ganho de corretude com a ordenacao estrita. A conversao para Standard restaurou o paralelismo sem perda de integridade.

---

## 9. Frontend: localStorage, JWT e operacoes assincronas

### JWT em localStorage

O token JWT e armazenado em `localStorage` (chave `oms_token`). A escolha e motivada pela arquitetura do frontend:

- **E uma SPA servida por S3 Static Website** - nao ha um servidor Node para fazer `Set-Cookie` com flag HttpOnly.
- **Nao ha backend de sessao** - todo o estado de autenticacao e gerenciado no cliente.
- **Risco aceito:** XSS pode ler `localStorage`. Em producao, mitigacoes incluiriam Content Security Policy, HttpOnly cookie com BFF (Backend for Frontend) pattern.

### Operacoes assincronas (202)

Cancelamento e atualizacao de pedidos retornam HTTP 202, nao 200:

```mermaid
sequenceDiagram
    participant F as Frontend
    participant GW as order_gateway
    participant EB as EventBridge
    participant SQS as SQS Queue
    participant LC as lifecycle_ops
    participant DDB as DynamoDB

    F->>GW: POST /orders/ORD-123/cancel
    GW->>EB: OrderCancelled event
    GW-->>F: 202 {"message": "Cancellation requested"}
    Note over F: Exibe "solicitado, aguarde"
    EB->>SQS: regra roteia
    SQS->>LC: record
    LC->>DDB: UpdateItem (status=CANCELLED)
    F->>F: Refresh apos 3s
    F->>GW: GET /orders/ORD-123
    GW-->>F: 200 {"status": "CANCELLED"}
```

O frontend exibe feedback imediato ("solicitado, aguarde") e faz refresh apos 3 segundos para mostrar o estado atual, sem polling agressivo.

### Ponte clienteId/clientId

O campo `clienteId` no JWT (payload do token) corresponde ao campo `clientId` no DynamoDB. A ponte funciona em tres camadas:

1. **Frontend:** injeta `{"pedidoId","clienteId","itens"}` no `POST /orders` extraindo `clienteId` do `localStorage`.
2. **order_processor:** armazena o atributo `clientId` no DynamoDB (o nome do campo e diferente na tabela).
3. **order_gateway:** faz a ponte explicitamente: extrai `clienteId` do JWT e busca por `clientId` no GSI.

---

## 10. O que seria diferente em producao real

### Itens de melhoria para ambiente de producao

| Item | Solucao atual | Producao real | Motivo da nao adocao |
|---|---|---|---|
| Autenticacao | JWT HS256 manual em `common/auth.py` | Cognito User Pools com Lambda Authorizer | Conta de laboratorio sem Cognito |
| Gerenciamento de segredo | Arquivo `.jwt-secret` local | AWS Secrets Manager com rotacao automatica | Conta de laboratorio sem Secrets Manager |
| Autorizacao de endpoints | Validacao JWT inline em cada Lambda | Lambda Authorizer ou Cognito Authorizer centralizado | Simplicidade em sistema pequeno |
| Restricao de rede | API Gateway Resource Policy + Usage Plan | WAF com IP Set e Rate Rule | Conta de laboratorio sem WAF |
| Rastreamento distribuido | `log_event()` com JSON estruturado | AWS X-Ray com sampling ativo | Conta de laboratorio sem X-Ray |
| IaC | Shell scripts com `ensure_*` idempotente | Terraform ou CDK com plan preview | Escopo educacional (expor APIs AWS reais) |
| CDN e HTTPS | S3 Static Website direto | CloudFront com OAI para HTTPS e cache de borda | Simplicidade; LocalStack nao suporta CloudFront |
| Seguranca de rede | Lambdas em VPC default | VPC com endpoints privados e NAT Gateway | Custo e complexidade desnecessarios para laboratorio |
| Pagamento real | Sem integracao de pagamento | Stripe, PagSeguro ou Gateway de pagamento como etapa entre PROCESSED | Escopo do projeto e gerenciamento de pedidos |
| Testes unitarios | `validate-flow.sh` E2E via AWS CLI | pytest com moto para testes unitarios e de integracao | Escopo educacional; E2E cobre cenarios principais |
