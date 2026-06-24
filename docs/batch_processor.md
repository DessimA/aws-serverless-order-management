# Lambda `batch_processor` (`src/batch_processor/index.py`)

## Finalidade

Processa arquivos JSON enviados ao bucket S3. Valida o schema (presença de `lista_pedidos`), registra auditoria no DynamoDB e dispara alertas SNS em caso de erro.

## Comportamento

1. Recebe notificação S3 via SQS Standard.
2. Extrai o evento S3 diretamente do corpo da mensagem (notificação S3 -> SQS direta).
3. Para cada objeto criado no S3:
    - Baixa o arquivo e valida o schema JSON.
    - Se válido: registra `PROCESSED` na tabela de auditoria.
    - Se inválido: registra `ERROR` e publica alerta SNS via `common.sns.publish_error()`.
4. Erros no parse do record SQS são adicionados a `batchItemFailures`.

## Ambiente

| Variável | Descrição |
|----------|-----------|
| `DYNAMODB_TABLE` | Nome da tabela de auditoria |
| `SNS_TOPIC_ARN` | ARN do topico SNS para alertas de schema inválido |

## Politica de retenção

Registros de auditoria expiram apos 90 dias via TTL no DynamoDB. O campo `expiresAt` (epoch seconds) e calculado no momento da inserção por `common.utils.utcnow_plus_days_epoch(90)`. Apos expiração, o DynamoDB remove automaticamente os registros sem custo adicional de armazenamento.

