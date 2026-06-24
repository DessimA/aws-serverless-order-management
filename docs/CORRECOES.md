# Decisoes de Implementacao

## Visao Geral

CloudCert e uma plataforma serverless de e-commerce para cursos e vouchers de certificacao em nuvem (AWS, Azure, GCP). O sistema implementa um pipeline de ingegestao de pedidos via API Gateway com Request Validator, bufferizacao em fila SQS FIFO, validacao e publicacao no EventBridge, que roteia eventos para filas SQS Standard de processamento. Cada Lambda de processamento persiste dados no DynamoDB com idempotencia via ConditionExpression.

O catalogo de produtos e publico e acessivel via endpoints GET. A autenticacao e feita por JWT HS256 implementado manualmente com stdlib Python (PBKDF2-SHA256, HMAC-SHA256), sem dependencias externas. O gateway de pedidos fornece endpoints autenticados para listagem, consulta com validacao de ownership, cancelamento e atualizacao. Processamento batch via S3 com notificacao direta para SQS e auditoria em tabela DynamoDB com TTL de 90 dias.

A arquitetura e orientada a eventos. Nenhuma chamada sincrona cruza fronteiras de servico. O barramento central EventBridge desacopla produtores de consumidores. Filas SQS com DLQ absorvem picos de carga e garantem resiliencia a falhas temporarias. O projeto opera exclusivamente via AWS CLI e shell scripts, sem frameworks de Infrastructure as Code.

## Convencoes de Codigo

- `parse_body()` e `parse_detail()` de `common.sqs` para leitura de records SQS em todas as Lambdas
- `batchItemFailures` obrigatorio em todas as Lambdas acionadas por SQS
- `api_response()` e `error_response()` de `common.http` em todas as Lambdas com integracao API Gateway
- `log_event(stage, pedido_id, message)` de `common.utils` para logging estruturado
- Nenhum comentario inline no codigo; razoes de design em `docs/`
- Nenhum caractere travessao longo em nenhum arquivo

## Padroes de Infraestrutura

- `set -euo pipefail` em todos os scripts shell
- Padrao check-before-create (idempotencia): verificar existencia antes de criar recurso
- `VisibilityTimeout=360s` (6x o timeout de Lambda de 60s)
- `ReportBatchItemFailures` em todos os event source mappings SQS
- `validate_lambda_config` apos cada `ensure_lambda_function`
- `lambda add-permission` com `source-arn` especifico por metodo/recurso
- Reserved Concurrency: 5 para Lambdas de processamento, 10 para gateway e catalogo
- Log retention de 14 dias em todos os grupos de log CloudWatch
- DLQ com `maxReceiveCount=3` e CloudWatch Alarm para cada fila
- TTL de 90 dias na tabela de auditoria DynamoDB

