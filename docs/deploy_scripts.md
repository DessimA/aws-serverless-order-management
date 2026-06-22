# Scripts de Deploy (`scripts/`)

## Finalidade

Infraestrutura como Codigo (IaC) via AWS CLI. Cada script provisiona um conjunto de recursos de forma idempotente.

## `lib.sh`

Biblioteca compartilhada com 20+ funcoes utilitarias.

### Mudancas recentes

| Funcao | Mudanca |
|--------|---------|
| `validate_env()` | Agora chama automaticamente `validate_resource_suffix()` quando `RESOURCE_SUFFIX` esta presente. |
| `validate_resource_suffix()` | Nova funcao: valida formato `[a-z0-9-]` do sufixo, falhando cedo se invalido. |
| `ensure_sqs_queue()` | `VisibilityTimeout` agora usa a variavel `$VISIBILITY_TIMEOUT` (padrao 360s). |
| `validate_sqs_queue()` | Validacao de VisibilityTimeout usa a mesma variavel. |
| `ensure_event_source_mapping()` | Cria/atualiza mapeamento com `--function-response-types ReportBatchItemFailures`. |

## `deploy-order-processor.sh`

- Adicionado `SNS_TOPIC_ARN` nas variaveis de ambiente da Lambda.
- Adicionada permissao `sns:Publish` na role IAM.
- `validate_lambda_config` agora valida `SNS_TOPIC_ARN`.

## `deploy-lifecycle-ops.sh`

- Resolucao do `SNS_TOPIC_ARN` via AWS CLI dentro da funcao `deploy_lifecycle_handler`.
- Adicionada permissao `sns:Publish` para alertas de pedido inexistente.
- `validate_lambda_config` agora valida `SNS_TOPIC_ARN`.

## `lib.sh` (Rodada 5)

| Funcao | Mudanca |
|--------|---------|
| `ensure_lambda_function()` | Agora aceita 7o parametro `reserved_concurrency`. Aplica `put-function-concurrency` quando definido. Tambem adiciona retention policy de 14 dias no log group. |
| `ensure_dlq_alarm()` | Nova funcao: cria CloudWatch Alarm monitorando `ApproximateNumberOfMessagesVisible` para DLQ, com acao SNS. Idempotente (checa existencia antes de criar). |
| `ensure_api_resource_policy()` | Nova funcao: aplica Resource Policy no API Gateway. Usa padrao Allow geral + Deny condicional para /test. |
| `ensure_usage_plan_with_api_key()` | Nova funcao: cria Usage Plan com throttle (rateLimit=5, burstLimit=10) e quota (1000 req/dia), cria API Key e associa. |

## `deploy-api-flow.sh` (Rodada 5)

- Resource Policy aplicada no REST API quando `ALLOWED_SOURCE_IP` esta definido.
- Request Validator (JSON Schema) criado para metodo POST /orders, validando presenca de `pedidoId` e `clienteId` antes de invocar a Lambda.

## `deploy-s3-flow.sh` (Rodada 5)

- TTL habilitado na tabela de auditoria DynamoDB (`order-batch-audit-*`) com `expiresAt` em 90 dias.
- DLQ alarm criado para `order-s3-batch-dlq-*`.

## `deploy-order-processor.sh` (Rodada 5)

- DLQ alarm criado para `order-persister-dlq-*`.

## `deploy-lifecycle-ops.sh` (Rodada 5)

- DLQ alarm criado para `cancel-order-dlq-*` e `update-order-dlq-*`.

## `deploy-frontend.sh` (Rodada 5)

- API Key obrigatoria no metodo POST /test (`--api-key-required`).
- Usage Plan criado com throttle e quota, associado ao stage prod.
- Frontend envia header `x-api-key` em todas as chamadas a /test.

## `validate-flow.sh`

- Adicionado Teste 1b: Duplicidade - reenvia o mesmo pedidoId e verifica que:
  - A API aceita (SQS dedup bypassed por uuid4).
  - O DynamoDB mantem o registro original (ConditionExpression).
- Adicionado SNS_TOPIC_ARN nas variaveis para verificacao de alertas.
- Adicionado Teste 6a: POST /test sem API Key retorna 403.
- Adicionado Teste 10: Verificacao de retentionInDays=14 nos log groups.
- Adicionado Teste 11: Verificacao de existencia dos 5 DLQ alarms.
- Adicionado Teste 12: Verificacao de ReservedConcurrentExecutions configurado.
- Adicionado Teste 13: Verificacao de TimeToLiveStatus=ENABLED na tabela de auditoria.

## Notas de validacao manual

## `scripts/lib.sh` (Rodada 6)

- `ensure_api_resource_policy()`: Resource ARN restrito a `*/*/POST/test` (antes cobria toda a API). Movido de `deploy-api-flow.sh` para `deploy-frontend.sh`.

## `scripts/validate-flow.sh` (Rodada 6)

- Teste 14: Test Controller detailType Allowlist - envia detailType invalido (`OrderCreated`) e verifica retorno 400.

## `scripts/lib.sh` (Rodada 7)

- `ensure_api_resource_policy()`: Alterado do padrao Allow-only para Allow geral + Deny condicional. Antes, a politica tinha apenas uma declaracao Allow com IpAddress, que bloqueava implicitamente as demais rotas. Agora, uma declaracao Allow irrestrita cobre toda a API (Resource `/*`) e uma declaracao Deny separada com NotIpAddress restringe apenas `/POST/test`.

### Resource Policy (Rodada 7 - Item 1)
A Resource Policy agora segue o padrao Allow geral + Deny condicional, que e o correto para restricao parcial em Resource Policies do API Gateway (Deny sempre precede Allow na avaliacao).

Para testar a restricao de IP em /test:
1. Defina `ALLOWED_SOURCE_IP=SEU_IP/32` no .env e execute o deploy.
2. De outro IP (ou remova o header), tente chamar POST /test.
3. A resposta deve ser 403 Forbidden.
4. Com `ALLOWED_SOURCE_IP` vazio, o comportamento atual e mantido (sem restricao).
5. POST /orders e GET /orders/{orderId} continuam funcionando de qualquer IP, mesmo com ALLOWED_SOURCE_IP definido.

O Teste 15 em `validate-flow.sh` faz validacao estrutural automatizada da politica (verifica a presenca das declaracoes Allow e Deny com os Resources e Conditions corretos) sem depender de troca de IP de origem. O teste funcional completo (trocar IP de origem para confirmar 403/200) continua manual.

### Fluxo de avaliacao da Resource Policy antes e depois

```mermaid
flowchart TD
    subgraph "ANTES (Allow-only com IpAddress)"
        A1["Request para qualquer rota<br/>(/orders, /test, etc)"] --> B1{"Policy tem<br/>declaracao Allow<br/>que cobre esta rota<br/>E condicao IP<br/>e satisfeita?"}
        B1 -->|"Sim (apenas /test<br/>do IP correto)"| C1["200 OK"]
        B1 -->|"Nao (demais rotas<br/>ou IP diferente)"| D1["403 Forbidden<br/>(deny-by-default)"]
    end

    subgraph "DEPOIS (Allow geral + Deny condicional)"
        A2["Request para qualquer rota"] --> B2{"Declaracao Deny<br/>cobre esta rota<br/>E condicao IP<br/>e violada?"}
        B2 -->|"Sim (/test de IP<br/>nao autorizado)"| C2["403 Forbidden"]
        B2 -->|"Nao (qualquer rota<br/>ou IP autorizado)"| D2["200 OK<br/>(Allow geral)"]
    end

    style D1 fill:#ffcccc
    style C1 fill:#ccffcc
    style C2 fill:#ffcccc
    style D2 fill:#ccffcc
```

No fluxo "antes", o deny-by-default do API Gateway bloqueava qualquer rota nao coberta por uma declaracao Allow explicita. Como a unica declaracao Allow era para `*/POST/test` com IpAddress, as rotas `/orders` e `/orders/{orderId}` ficavam sem declaracao e eram bloqueadas. No fluxo "depois", o Allow geral cobre toda a API, e apenas `/POST/test` tem um Deny condicional com NotIpAddress, que so bloqueia quando o IP nao e o permitido.

## `scripts/validate-flow.sh` (Rodada 7)

- Teste 15: Resource Policy structural validation - valida estruturalmente a politica quando ALLOWED_SOURCE_IP esta definido, verificando presenca de declaracao Allow com Resource `/*` e declaracao Deny com Resource `/POST/test` e Condition NotIpAddress. SKIP se ALLOWED_SOURCE_IP vazio.

## `deploy-catalog.sh` (Rodada 9)

- Cria tabela DynamoDB `course-catalog-*` com chave `cursoId` (S).
- Cria IAM Role com permissoes `dynamodb:Scan` e `dynamodb:GetItem`.
- Deploy da Lambda `catalog-reader-*` com `reserved_concurrency=10`.
- Cria recursos `/catalog` e `/catalog/{cursoId}` no API Gateway.
- `setup_api_cors` em ambos os recursos.
- `lambda add-permission` com `source-arn` especifico (`*/GET/catalog`, `*/GET/catalog/{cursoId}`).
- Path parameter `cursoId` configurado como obrigatorio.

## `seed-catalog.sh` (Rodada 9)

- Script idempotente que popula a tabela `course-catalog-*` com 11 itens.
- Usa `put-item` sem `ConditionExpression` (upsert idempotente).
- Um item (`GCP-PCA-001`) e inserido com `disponivel=false` para validacao de filtro.
- Ao final, exibe contagem total de itens na tabela.

## `validate-flow.sh` (Rodada 9)

- Adicionada chamada a `deploy-catalog.sh` e `seed-catalog.sh` antes de `deploy-frontend.sh`.
- Teste 19: GET /catalog - verifica que items retorna lista com count > 0 e que GCP-PCA-001 (disponivel=false) nao esta presente.
- Teste 20: GET /catalog/{cursoId} - verifica que AWS-CP-001 retorna item completo e GCP-PCA-001 retorna 404.
