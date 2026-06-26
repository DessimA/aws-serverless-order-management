# Decisoes de Implementacao

## Visao Geral

CloudCert e uma plataforma serverless de e-commerce para cursos e vouchers de certificacao em nuvem (AWS, Azure, GCP). O sistema implementa um pipeline de ingestao de pedidos via API Gateway com Request Validator, bufferizacao em fila SQS FIFO, validacao e publicacao no EventBridge, que roteia eventos para filas SQS Standard de processamento. Cada Lambda de processamento persiste dados no DynamoDB com idempotencia via ConditionExpression.

O catalogo de produtos e publico e acessivel via endpoints GET. A autenticacao e feita por JWT HS256 implementado manualmente com stdlib Python (PBKDF2-SHA256, HMAC-SHA256), sem dependencias externas. O gateway de pedidos fornece endpoints autenticados para listagem, consulta com validacao de ownership, cancelamento e atualizacao. Processamento batch via S3 com notificacao direta para SQS e auditoria em tabela DynamoDB com TTL de 90 dias.

A arquitetura e orientada a eventos. Nenhuma chamada sincrona cruza fronteiras de servico. O barramento central EventBridge desacopla produtores de consumidores. Filas SQS com DLQ absorvem picos de carga e garantem resiliencia a falhas temporarias. O provisionamento da infraestrutura e feito com Terraform, e os scripts shell orquestram o ciclo de deploy e validacao.

## Convencoes de Codigo

- `parse_body()` e `parse_detail()` de `common.sqs` para leitura de records SQS em todas as Lambdas
- `batchItemFailures` obrigatorio em todas as Lambdas acionadas por SQS
- `api_response()` e `error_response()` de `common.http` em todas as Lambdas com integracao API Gateway
- `log_event(stage, pedido_id, message)` de `common.utils` para logging estruturado
- Nenhum comentario inline no codigo; razoes de design em `docs/`
- Nenhum caractere travessao longo em nenhum arquivo

## Padroes de Infraestrutura

- Infraestrutura como codigo com Terraform (HCL), nomes de recursos via `locals.tf`
- `set -euo pipefail` em todos os scripts shell
- `VisibilityTimeout=360s` (6x o timeout de Lambda de 60s)
- `ReportBatchItemFailures` em todos os event source mappings SQS
- Reserved Concurrency: 5 para Lambdas de processamento, 10 para gateway e catalogo
- Log retention de 14 dias em todos os grupos de log CloudWatch
- DLQ com `maxReceiveCount=3` e CloudWatch Alarm para cada fila (via modulo sqs_with_dlq)
- TTL de 90 dias na tabela de auditoria DynamoDB

## Refinamentos e Correcoes

1. `frontend/app.js`: XSS via onclick inline substituido por event delegation com data-order-id
2. `frontend/app.js`, `frontend/qa.js`: escapeHtml agora escapa aspas simples (`&#39;`)
3. `frontend/app.js`: botoes de login e registro desabilitados durante requisicao (double-submit)
4. `scripts/validate-flow.sh`: Tests 23 e 24 corrigidos para usar arquivo temporario unico (uma chamada curl cada)
5. `src/catalog_reader/index.py`: removido `import json` nao utilizado
6. `src/order_processor/index.py`: `order_id` inicializado como `None` antes do bloco try
7. `frontend/app.js`, `frontend/index.html`: `alert()` substituido por `showToast()` com notificacao temporaria
8. `frontend/app.js`: botao "Comprar" exibe spinner e desabilita durante requisicao
9. `frontend/app.js`: banner de processamento assincrono exibido apos compra em "Meus Pedidos"
10. `src/order_gateway/index.py`: `list_handler` agora itera sobre paginas do DynamoDB (LastEvaluatedKey)
11. `src/catalog_reader/index.py`: `list_handler` agora itera sobre paginas do scan DynamoDB
12. `frontend/qa.html`, `frontend/style.css`: estilos inline migrados para CSS
13. `frontend/app.js`, `frontend/qa.js`: removida constante duplicada `API_ENDPOINT` em favor de `ORDERS_ENDPOINT`; config.js removido do repositorio e gerado pelo Terraform via `locals.tf` config_js_content
14. `README.md`: removido placeholder `$FRONTEND_URL` e referencia a "rodadas"
15. `SECURITY.md`: descricao do frontend principal corrigida (portfolio product vs testing tool)
16. `docs/deploy.md`: documentacao de deploy baseada em Terraform
17. `docs/CORRECOES.md`: corrigido typo "ingegestao" para "ingestao"

