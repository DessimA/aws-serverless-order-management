# AWS Serverless Order Management System

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Python](https://img.shields.io/badge/Python-3.12-blue.svg)](https://www.python.org/downloads/release/python-3120/)
[![AWS](https://img.shields.io/badge/AWS-Serverless-orange.svg)](https://aws.amazon.com/serverless/)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

## 1. Introdução
Este projeto documenta a construção de um sistema de gerenciamento de pedidos escalável e resiliente, utilizando uma arquitetura orientada a eventos (Event-Driven Architecture - EDA). A solução foi projetada para lidar com alta concorrência, garantindo a integridade dos dados e o desacoplamento entre os produtores de pedidos e os processadores de negócio.

O sistema suporta múltiplos canais de entrada e gerencia o ciclo de vida completo de um pedido, desde a validação inicial até estados finais como alteração de itens ou cancelamento.

## 2. Arquitetura do Sistema

A arquitetura utiliza SQS FIFO como buffer de validação, EventBridge como barramento de eventos central, e SQS como buffer de processamento para cada operação. Abaixo, o fluxograma técnico da solução:

```mermaid
graph LR
    subgraph "Camada de Ingestao"
        A[Cliente API] -- HTTP POST --> B(API Gateway)
        B -- Proxy --> C{Lambda Pre-Validator}
        C --> D[SQS FIFO<br/>Validacao]
        D --> E{Lambda Validator}
        F[Parceiro S3] -- JSON Upload --> G[(S3 Data Lake)]
        G -- Event Notification --> H[SQS Standard<br/>Arquivos]
        H --> I{Lambda File Validator}
    end

    subgraph "Roteamento de Eventos (Bus)"
        E -- Publish --> J[EventBridge Custom Bus]
        I -- Audit Log --> K[(DynamoDB Audit)]
        I -- Error Alert --> L[SNS Notifications]
    end

    subgraph "Operacoes de Ciclo de Vida"
        J -- Rule --> M[SQS FIFO<br/>Pedidos Pendentes] -- Trigger --> N{Order Processor}
        J -- Rule --> O[SQS FIFO<br/>Cancelar Pedido] -- Trigger --> P{Cancel Processor}
        J -- Rule --> Q[SQS FIFO<br/>Alterar Pedido] -- Trigger --> R{Update Processor}
    end

    subgraph "Persistencia"
        N -- Create --> S[(DynamoDB Production)]
        P -- Update --> S
        R -- Update --> S
    end

    subgraph "Frontend de Testes"
        T[S3 Static Website<br/>Testing Dashboard]
        T -- POST --> B
        T -- POST --> X{Test Controller<br/>Lambda}
        T -- GET --> Y[GET /orders/:id]
        Y --> V[Lambda Order Reader]
        X -- Publish --> J
        X -- Upload --> G
    end

    %% Estilizacao para alto contraste (Fonte Branca)
    style A fill:#232F3E,stroke:#fff,color:#fff
    style B fill:#4A148C,stroke:#fff,color:#fff
    style C fill:#333399,stroke:#fff,color:#fff
    style D fill:#880E4F,stroke:#fff,color:#fff
    style E fill:#333399,stroke:#fff,color:#fff
    style F fill:#232F3E,stroke:#fff,color:#fff
    style G fill:#1B5E20,stroke:#fff,color:#fff
    style H fill:#880E4F,stroke:#fff,color:#fff
    style I fill:#333399,stroke:#fff,color:#fff
    style J fill:#BF360C,stroke:#fff,stroke-width:4px,color:#fff
    style K fill:#0D47A1,stroke:#fff,color:#fff
    style L fill:#880E4F,stroke:#fff,color:#fff
    style M fill:#880E4F,stroke:#fff,color:#fff
    style N fill:#333399,stroke:#fff,color:#fff
    style O fill:#880E4F,stroke:#fff,color:#fff
    style P fill:#333399,stroke:#fff,color:#fff
    style Q fill:#880E4F,stroke:#fff,color:#fff
    style R fill:#333399,stroke:#fff,color:#fff
    style S fill:#0D47A1,stroke:#fff,color:#fff
    style T fill:#1B5E20,stroke:#fff,color:#fff
    style X fill:#333399,stroke:#fff,color:#fff
    style Y fill:#4A148C,stroke:#fff,color:#fff
    style V fill:#333399,stroke:#fff,color:#fff
```

## 3. Stack Tecnológica
*   **Linguagem de Programação:** Python 3.12 utilizando o SDK Boto3.
*   **Infraestrutura como Código (IaC):** Automação via Shell Scripting e AWS CLI.
*   **Serviços AWS:**
    *   **Amazon API Gateway:** Ponto de entrada REST para integração síncrona.
    *   **AWS Lambda:** Execução de lógica de negócio serverless (6 funções).
    *   **Amazon S3:** Armazenamento de objetos para processamento em lote.
    *   **Amazon SQS:** Filas FIFO para buffers de validação e processamento; filas Standard para notificações S3.
    *   **Amazon EventBridge:** Orquestrador de eventos para desacoplamento total.
    *   **Amazon DynamoDB:** Banco de dados NoSQL (tabela de produção + tabela de auditoria).
    *   **Amazon SNS:** Serviço de notificações para alertas de erro.
    *   **AWS IAM:** Gerenciamento de permissões baseado no princípio de menor privilégio.
*   **Ambiente Local:** LocalStack Pro (via Docker) para emulação de serviços AWS.

---

## 4. Detalhamento dos Componentes

### 4.1. Camada de Ingestão Síncrona (API)
O fluxo inicia no **Amazon API Gateway**, que expõe um endpoint REST. A requisição é encaminhada para a Lambda `pre_validator`. Esta função realiza o parse do JSON, valida a presença de campos obrigatórios (`pedidoId` e `clienteId`), e envia a mensagem para uma **fila SQS FIFO** (`order-validation-buffer`). Imediatamente retorna `200` ao cliente com o pedido aceito.

A Lambda `order_validator` consome a fila FIFO, publica o pedido validado no **Amazon EventBridge Custom Bus** com `DetailType: OrderValidated`, e em caso de falha dispara um alerta via **SNS**. O uso do SQS FIFO como buffer garante:
- **Desacoplamento:** A resposta ao cliente não depende da disponibilidade do EventBridge.
- **Ordenação:** Pedidos são processados na ordem de chegada (MessageGroupId = pedidoId).
- **Deduplicação:** A identificação única de cada mensagem SQS é garantida por um UUID gerado no momento do envio, permitindo que reenvios do mesmo pedidoId cheguem até a camada de persistência. A duplicidade de negócio é tratada pelo `ConditionExpression: attribute_not_exists(orderId)` no DynamoDB, com alerta SNS em caso de duplicata.

### 4.2. Camada de Ingestão Assíncrona (S3 — Audit-Only)
Projetada para integração com sistemas legados ou parceiros que exportam arquivos. Quando um arquivo JSON é carregado no **Amazon S3**, uma notificação de evento é enviada para uma fila **SQS Standard**. A Lambda `file_validator` (anteriormente `batch_processor`) consome esta fila, baixa o arquivo e valida o schema (presença da chave `lista_pedidos`).
*   **Auditoria:** Cada arquivo processado tem seu status (PROCESSED ou ERROR) registrado na tabela DynamoDB de auditoria.
*   **Alertas:** Em caso de falha no schema do arquivo, um alerta é disparado via **Amazon SNS**.
*   **Nota:** Diferente de versões anteriores, este fluxo **não** publica eventos no EventBridge. Pedidos em lote são apenas validados e auditados — não criam registros na tabela de produção.

### 4.3. Barramento de Eventos (EventBridge)
Atua como o sistema nervoso central da arquitetura. Ele recebe eventos exclusivamente da Lambda `order_validator` (fluxo API síncrono). Através de **Regras (Rules)** baseadas em padrões de eventos (`source` e `detail-type`), o EventBridge roteia os dados para as filas SQS FIFO específicas de cada operação (Criação, Alteração ou Cancelamento).

Cada regra do EventBridge para filas FIFO especifica obrigatoriamente um `MessageGroupId` via `SqsParameters`, exigência da AWS para entrega em filas FIFO.

### 4.4. Camada de Persistência e Ciclo de Vida
As Lambdas de processamento final são acionadas por filas SQS FIFO que atuam como buffers de carga.
*   **Order Processor:** Cria o registro inicial na tabela `order-production-data` com `ConditionExpression: attribute_not_exists(orderId)` para impedir sobrescrita de pedidos duplicados.
*   **Update Processor:** Atualiza itens de pedidos existentes utilizando `UpdateExpression` e `ConditionExpression: attribute_exists(orderId)` para garantir que o pedido existe antes de alterá-lo.
*   **Cancel Processor:** Altera o status do pedido para `CANCELLED` com `ConditionExpression: attribute_exists(orderId)`, prevenindo criação de registros fantasmas.

Todas as três Lambdas utilizam a função `parse_detail()` do módulo `common.sqs`, que trata corretamente o campo `detail` do envelope EventBridge independentemente de chegar como string ou objeto JSON nativo.

### 4.5. Camada de Consulta (Leitura de Pedidos)
A Lambda `read_order` expõe um endpoint `GET /orders/{orderId}` no API Gateway existente. Ela consulta a tabela DynamoDB `order-production-data` via `GetItem` e retorna o item completo ou `404` se não encontrado. Respostas incluem headers CORS para integração com o frontend.

### 4.6. Controlador de Testes (`test_controller`)
Lambda auxiliar de uso interno (rota `POST /test` do mesmo API Gateway) que orquestra três ações:
- **`publish_event`**: Publica eventos de ciclo de vida (`OrderCancelled`/`OrderUpdated`) no EventBridge para testar os fluxos de cancelamento/atualização.
- **`upload_file`**: Faz upload de conteúdo para o bucket S3 de dados, acionando o fluxo de validação assíncrona (`file_validator` → DynamoDB Audit + SNS).
- **`list_files`**: Lista arquivos no bucket S3 para verificação pós-teste.

## 5. Estrutura do Projeto

A organização do repositório segue padrões de modularidade para facilitar a manutenção e o deploy independente de componentes:

```text
aws-serverless-order-ingestion/
├── .github/                    # Templates de contribuicao
│   ├── ISSUE_TEMPLATE/
│   │   ├── bug_report.md       # Template de report de bug
│   │   └── feature_request.md  # Template de solicitacao de funcionalidade
│   └── PULL_REQUEST_TEMPLATE.md # Template de Pull Request
├── scripts/                    # Infraestrutura como Codigo (IaC) e Deploy
│   ├── lib.sh                  # 19 funcoes utilitarias (deploy, validacao, IAM, SQS, EventBridge)
│   ├── deploy-api-flow.sh      # Provisiona API Gateway, SQS FIFO, Pre-Validator e Validator
│   ├── deploy-s3-flow.sh       # Provisiona S3, SQS Standard, File Validator e Auditoria
│   ├── deploy-order-processor.sh # Provisiona o Processador Central (persistencia)
│   ├── deploy-lifecycle-ops.sh # Provisiona fluxos de Alterar e Cancelar
│   ├── deploy-frontend.sh      # Frontend S3 + Lambdas read_order + test_controller
│   └── validate-flow.sh        # Script automatizado de testes E2E
├── src/                        # Codigo-fonte das funcoes AWS Lambda
│   ├── common/                 # Modulos utilitarios compartilhados (http, sqs, sns, utils)
│   ├── pre_validator/          # Logica de pre-validacao e envio para SQS FIFO
│   ├── order_validator/        # Logica de validacao (SQS → EventBridge + SNS)
│   ├── batch_processor/        # Logica de extracao de arquivos e auditoria (S3 → DynamoDB)
│   ├── order_processor/        # Persistencia do estado inicial do pedido
│   ├── lifecycle_ops/          # Operacoes de atualizacao e cancelamento
│   ├── read_order/             # Leitura de pedidos (GET /orders/{id})
│   └── test_controller/        # Controlador de testes (EventBridge + S3 upload)
├── frontend/                   # Dashboard de testes (S3 Static Website)
│   ├── index.html              # Interface com abas para cada fluxo
│   ├── style.css               # Tema escuro responsivo
│   ├── config.template.js      # Template com placeholders (processado pelo deploy)
│   └── app.js                  # Logica de teste por seção (Novo Pedido, Consultar, Gerenciar, Upload)
├── samples/                    # Exemplos de payloads para testes e integracao
│   ├── api_request.json        # Modelo de requisicao para o API Gateway
│   ├── valid_batch.json        # Modelo de arquivo para processamento S3
│   └── invalid_batch.json      # Modelo para teste de falha e alerta SNS
├── .env.example                # Template de variaveis de ambiente
├── CODE_OF_CONDUCT.md          # Codigo de Conduta (Contributor Covenant v2.1)
├── CONTRIBUTING.md             # Guia de contribuicao
├── docker-compose.yaml         # Orquestracao do ambiente LocalStack Pro
├── LICENSE                     # Licenca MIT
├── run.sh                      # Script principal de automacao do Lab
├── SECURITY.md                 # Politica de seguranca e report de vulnerabilidades
└── README.md                   # Documentacao tecnica completa
```

---

## 6. Pré-requisitos Técnicos

Antes de iniciar a implantação, certifique-se de ter as seguintes ferramentas instaladas e configuradas:

*   **AWS CLI v2:** Configurado com credenciais válidas (`aws configure`).
*   **Python 3.12:** Necessário para a execução das funções Lambda.
*   **Docker e Docker Compose:** Obrigatórios para a execução via LocalStack.
*   **Utilitário Zip:** Utilizado pelos scripts de automação para empacotar o código-fonte das Lambdas.
*   **JQ (Opcional):** Recomendado para formatar as saídas JSON no terminal.

## 7. Configuração do Ambiente

O projeto utiliza um arquivo de variáveis de ambiente para centralizar as configurações e evitar a exposição de dados sensíveis.

1.  Localize o arquivo `.env.example` na raiz do projeto.
2.  Crie uma cópia chamada `.env`:
    ```bash
    cp .env.example .env
    ```
3.  Preencha as variáveis conforme as instruções abaixo:
    *   `AWS_REGION`: Região de destino (ex: `us-east-2`).
    *   `RESOURCE_SUFFIX`: Identificador único para evitar conflitos de nomes (ex: seu nome).
    *   `NOTIFICATION_EMAIL`: E-mail que receberá os alertas do Amazon SNS.
    *   `LOCALSTACK_AUTH_TOKEN`: Seu token de acesso (necessário para recursos Pro no LocalStack).

## 8. Execução via LocalStack (Desenvolvimento Local)

Este projeto foi validado utilizando o LocalStack Pro, permitindo um ciclo de desenvolvimento rápido e sem custos de infraestrutura.

1.  **Subir o container:**
    ```bash
    docker-compose up -d
    ```
2.  **Verificar a saúde do ambiente:**
    Acesse `http://localhost:4566/_localstack/health` para garantir que os serviços (Lambda, SQS, S3, DynamoDB, EventBridge) estão prontos.
3.  **Configurar o endpoint local (Opcional):**
    Para facilitar o uso do CLI apontando para o LocalStack, você pode utilizar o alias `awslocal` ou configurar o endpoint manualmente nos comandos.

## 9. Implantação Automatizada

O projeto conta com um orquestrador principal (`run.sh`) que gerencia a ordem de precedência das dependências.

Para realizar o deploy completo, execute:

```bash
chmod +x run.sh
./run.sh
```

### O que o script realiza:
1.  **Validação de Permissões:** Garante que todos os scripts na pasta `scripts/` são executáveis.
2.  **Deploy Fase 1 (API):** Cria o EventBus, SNS, SQS FIFO de validação, Lambdas `pre_validator` e `order_validator`, e API Gateway com integração CORS.
3.  **Deploy Fase 2 (S3):** Cria o bucket de dados, a fila SQS Standard, a Lambda `file_validator`, a tabela de auditoria DynamoDB, e a notificação S3 → SQS.
4.  **Deploy Fase 3 (Processor):** Cria a tabela DynamoDB de produção, a fila SQS FIFO de pedidos pendentes, a Lambda `order_persister`, e a regra EventBridge com `MessageGroupId`.
5.  **Deploy Fase 4 (Lifecycle):** Cria as filas SQS FIFO e Lambdas de alteração e cancelamento, com suas respectivas regras no EventBridge.
6.  **Deploy Fase 5 (Frontend):** Cria as Lambdas `read_order` e `test_controller`, adiciona os recursos `GET /orders/{orderId}` e `POST /test` ao API Gateway existente, cria o bucket S3 do frontend com Static Website Hosting, e faz upload dos arquivos com URLs injetadas.
7.  **Validação E2E:** Dispara automaticamente o script `validate-flow.sh` para testar todos os componentes.

### Utilitários (scripts/lib.sh)
Os scripts de deploy compartilham 19 funções utilitárias:

| Função | Descrição |
|--------|-----------|
| `load_env` | Carrega o `.env` de forma segura via `set -a` + `source` |
| `validate_env` | Valida que variáveis obrigatórias estão definidas |
| `wait_for_iam_role` | Polling ativo (12 tentativas, 5s) para propagação de IAM Role |
| `wait_for_sqs_queue` | Aguarda fila SQS ficar disponível após criação |
| `put_integration_response_cors` | Configura headers CORS em integration response do API Gateway |
| `sns_subscribe_email` | Inscreve e-mail no tópico SNS de forma idempotente |
| `validate_not_empty` | Valida que ARN/ID não está vazio ou `None` |
| `validate_lambda_config` | Valida timeout (60s) e variáveis de ambiente da Lambda |
| `validate_sqs_queue` | Valida VisibilityTimeout=90 e ContentBasedDeduplication (se FIFO) |
| `validate_sqs_policy` | Valida política resource-based da fila SQS |
| `validate_eventbridge_target` | Valida target da regra EventBridge (ARN + MessageGroupId) |
| `validate_esm` | Valida event source mapping SQS → Lambda (UUID + estado Enabled) |
| `put_eventbridge_target` | Configura target EventBridge com SqsParameters.MessageGroupId |
| `ensure_iam_lambda_role` | Cria role IAM Lambda com AWSLambdaBasicExecutionRole (idempotente) |
| `ensure_sqs_dlq` | Cria DLQ e retorna o ARN (FIFO ou Standard) |
| `ensure_sqs_queue` | Cria fila SQS com DLQ, VisibilityTimeout, URL/ARN e validação |
| `ensure_lambda_function` | Deploy Lambda com create/update, env vars e timeout |
| `ensure_event_source_mapping` | Cria ou ignora event source mapping SQS → Lambda |
| `setup_api_cors` | Configura OPTIONS + CORS completo em recurso do API Gateway |

---

## 10. Guia de Testes e Validação

O sistema pode ser validado de três formas: (1) via dashboard web, (2) via script automatizado, ou (3) via comandos manuais.

### 10.1. Teste via Dashboard Web (Recomendado)
Após executar `./run.sh`, o URL do dashboard é exibido no final do `deploy-frontend.sh`. Abra no navegador e utilize as abas:

1. **Novo Pedido**: Preencha Cliente, Produto, Quantidade e Preco; clique em "Criar Pedido". Use "Automatico" para gerar dados aleatórios. Teste cenários de erro no collapsible "Cenarios de Erro".
2. **Consultar**: Digite um Order ID e clique em "Consultar". Use "Ultimo Pedido" para preencher automaticamente o ID do último pedido criado.
3. **Gerenciar**: Informe um Order ID e use "Cancelar Pedido" ou "Atualizar Pedido". Teste cenários de pedido inexistente no collapsible "Cenarios de Erro".
4. **Upload**: Clique em "Gerar e Enviar Lote de Teste" para testar o fluxo de validação assíncrona via S3. Use "Listar Arquivos" para ver arquivos enviados. Teste schemas inválidos e arquivos corrompidos no collapsible "Cenarios de Erro".

O painel lateral exibe logs em tempo real com status e payloads de cada operação.

### 10.2. Teste via Script Automatizado
```bash
./scripts/validate-flow.sh
```
Este script executa todos os deploy scripts e testa cada fluxo via AWS CLI, verificando a persistência no DynamoDB.

### 10.3. Teste Manual via CLI

#### API Flow
```bash
curl -k -X POST <URL_DO_ENDPOINT>/prod/orders \
     -H "Content-Type: application/json" \
     -d '{"pedidoId": "ORD-001", "clienteId": "CLIENTE-TESTE", "itens": [{"sku": "PROD-A", "qtd": 1}]}'
```

#### S3 Batch (Audit-Only)
```bash
aws s3 cp samples/valid_batch.json s3://order-files-bucket-<seu-sufixo>/
```

#### Lifecycle Operations
```bash
aws events put-events --entries "[{
    \"Source\": \"app.orders.operations\",
    \"DetailType\": \"OrderUpdated\",
    \"Detail\": \"{\\\"pedidoId\\\": \\\"ORD-001\\\", \\\"novosItens\\\": [{\\\"sku\\\": \\\"PROD-B\\\", \\\"qtd\\\": 2}]}\",
    \"EventBusName\": \"orders-event-bus-<seu-sufixo>\"
}]"
```

## 11. Troubleshooting e Resolução de Problemas

Durante o desenvolvimento e implantação em ambientes reais da AWS ou LocalStack, alguns comportamentos comuns podem surgir. Abaixo estão as soluções aplicadas neste projeto:

### 11.1. Atraso na Propagação de IAM (Eventual Consistency)
**Problema:** O comando de criação da Lambda falha alegando que a Role não existe, mesmo após o comando de criação da Role ter retornado sucesso. </br>
**Solução:** Substituição de `sleep` fixo por polling ativo com `aws iam wait role-exists` (função `wait_for_iam_role` em `scripts/lib.sh`). O polling tenta a cada 5 segundos por até 60 segundos.

### 11.2. Erro de AccessDenied no S3 ou DynamoDB
**Problema:** A Lambda é executada, mas falha ao tentar ler um arquivo no S3 ou gravar no DynamoDB. </br>
**Causa:** Geralmente causada pela falta do caractere curinga `/*` no ARN do recurso na política IAM ou falta de permissões de leitura na Role. </br>
**Solução:** Revisão das políticas inline para garantir que o recurso seja `arn:aws:s3:::bucket-name/*` e inclusão de permissões explícitas para `s3:GetObject` e `dynamodb:PutItem`.

### 11.3. EventBridge não entrega mensagens no SQS FIFO
**Problema:** O evento é publicado com sucesso no barramento, mas a fila SQS FIFO de destino permanece vazia. </br>
**Causa 1:** A fila SQS precisa de uma **Resource-Based Policy** que autorize o serviço `events.amazonaws.com`. </br>
**Causa 2:** Filas FIFO exigem o parâmetro `SqsParameters.MessageGroupId` no target da regra do EventBridge. Sem ele, a AWS rejeita a entrega. </br>
**Solução:** Os scripts configuram automaticamente a política da fila com `Condition: SourceArn` e incluem `SqsParameters="{\"MessageGroupId\":\"...\"}"` no comando `put-targets`.

### 11.4. Conflito de Mapeamento de Eventos (LocalStack)
**Problema:** Erro `ResourceConflictException` ao tentar criar um gatilho SQS para uma Lambda que já possui esse mapeamento. </br>
**Solução:** Adição de lógica de verificação idempotente nos scripts de deploy, utilizando queries JMESPath para verificar se o `UUID` do mapeamento já existe antes de tentar criá-lo.

### 11.5. Erro de Resolução de Host (LocalStack)
**Problema:** O comando `curl` falha com `Could not resolve host` ao tentar acessar o API Gateway localmente. </br>
**Solução:** No ambiente LocalStack, a URL deve seguir o padrão `https://{api-id}.execute-api.localhost.localstack.cloud:4566`. O script de validação foi ajustado para detectar o ambiente e montar a URL correta.

## 12. Resiliência com Dead Letter Queues (DLQ) e Report Batch Item Failures

Todas as filas SQS deste projeto (Validação, Processamento, Alteração e Cancelamento) possuem uma DLQ associada.
*   **Configuração:** `maxReceiveCount` definido como 3, `VisibilityTimeout` parametrizado (padrão: 360s).
*   **Funcionamento:** Se uma Lambda falhar repetidamente ao processar uma mensagem (devido a erros de código ou indisponibilidade de recursos externos), a mensagem é movida para a DLQ após a terceira tentativa. Isso evita o bloqueio da fila principal.
*   **Report Batch Item Failures:** Todas as Lambdas acionadas por SQS implementam o padrão `batchItemFailures`, retornando apenas os `messageId` que falharam. Mensagens processadas com sucesso no mesmo lote não são reprocessadas, reduzindo o impacto de falhas parciais.
*   **Nota:** Filas padrão (batch S3) também possuem DLQ.

## 13. Testing Dashboard (Frontend)

O sistema inclui um dashboard de testes servido como S3 Static Website, acessível pelo URL exibido ao final do `deploy-frontend.sh`. Sua finalidade é permitir a validação manual de todos os fluxos (sucesso e falha) durante o desenvolvimento.

### 13.1. Interface

O dashboard é dividido em 4 abas, cada uma correspondendo a um fluxo do sistema:

| Aba | Ações de Sucesso | Ações de Falha |
|-----|-----------------|----------------|
| **Novo Pedido** | Criar Pedido → pre_validator → SQS FIFO → order_validator → EventBridge → Processor → DynamoDB | Faltando pedidoId (400), Faltando clienteId (400), JSON Inválido (400), Enviar Duplicata (ConditionalCheckFailedException → alerta SNS) |
| **Upload** | Gerar e Enviar Lote de Teste (lista_pedidos válido → DynamoDB Audit) | Schema Inválido (→ SNS Alert), Arquivo Corrompido (→ SNS Alert) |
| **Gerenciar** | Cancelar Pedido, Atualizar Pedido (EventBridge → SQS FIFO → Lifecycle Lambda → DynamoDB) | Cancelar Inexistente, Atualizar Inexistente (ConditionalCheckFailedException → alerta SNS) |
| **Consultar** | Consultar (GET /orders/{id} → DynamoDB) | Pedido Inexistente (404) |

### 13.2. Componentes do Frontend

| Arquivo | Descrição |
|---------|-----------|
| `frontend/index.html` | Estrutura do dashboard com inputs, botões e painel de logs |
| `frontend/style.css` | Tema escuro responsivo (grid de 2 colunas: painel + logs) |
| `frontend/config.template.js` | Template com placeholders (`__API_ENDPOINT__`, etc.) processado pelo deploy |
| `frontend/app.js` | Lógica de cada cenário de teste: chamadas fetch para API Gateway + processamento de respostas |

### 13.3. Novas Lambdas

| Lambda | Endpoint | Função |
|--------|----------|--------|
| `read_order` | `GET /orders/{orderId}` | Consulta DynamoDB production e retorna o pedido ou 404 |
| `test_controller` | `POST /test` | Roteia por ação (`publish_event`, `upload_file`, `list_files`) para testar lifecycle e S3 |

### 13.4. Painel de Logs

O dashboard exibe um painel lateral com logs em tempo real de cada operação, utilizando cores Bootstrap para indicar o status:
- <span style="color:var(--bs-success-text)">**Verde**</span>: Operação bem-sucedida (status 200/201 esperado)
- <span style="color:var(--bs-danger-text)">**Vermelho**</span>: Falha inesperada
- <span style="color:var(--bs-warning-text)">**Amarelo**</span>: Operação em andamento ou falha esperada

Cada entrada mostra timestamp, nome do teste, status HTTP e payload completo da resposta. Os cards de resultado inline utilizam ícones `check_circle` (sucesso), `error` (erro) e `warning` (aviso) do Material Icons.

### 13.5. Fluxos de Notificação SNS (E-mail)

| Gatilho | O que falha | Envia E-mail? |
|---------|------------|:---:|
| S3: Upload Invalid Schema | `file_validator` → `ValueError` (lista_pedidos ausente) | Sim |
| S3: Upload Corrupt File | `file_validator` → exceção de parse JSON | Sim |
| API: Duplicate Order | `order_processor` → `ConditionalCheckFailedException` (log + alerta SNS, sem DLQ) | Sim |
| Lifecycle: Non-existent | `cancel_processor`/`update_processor` → `ConditionalCheckFailedException` (log + alerta SNS, sem DLQ) | Sim |
| API: Validation Error | `order_validator` → erro no EventBridge ou parse (alerta SNS + DLQ após 3 retries) | Sim |

---
**Desenvolvido por [José Anderson](https://github.com/DessimA)**

---
