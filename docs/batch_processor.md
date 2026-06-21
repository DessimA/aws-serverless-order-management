# Lambda `batch_processor` (`src/batch_processor/index.py`)

## Finalidade

Processa arquivos JSON enviados ao bucket S3. Valida o schema (presenca de `lista_pedidos`), registra auditoria no DynamoDB e dispara alertas SNS em caso de erro.

## Comportamento

1. Recebe notificacao S3 via SQS Standard.
2. Extrai o evento S3 diretamente do corpo da mensagem (notificacao S3 -> SQS direta).
3. Para cada objeto criado no S3:
   - Baixa o arquivo e valida o schema JSON.
   - Se valido: registra `PROCESSED` na tabela de auditoria.
   - Se invalido: registra `ERROR` e publica alerta SNS.
4. Erros no parse do record SQS sao adicionados a `batchItemFailures`.

## Ambiente

| Variavel | Descricao |
|----------|-----------|
| `DYNAMODB_TABLE` | Nome da tabela de auditoria |
| `SNS_TOPIC_ARN` | ARN do topico SNS para alertas de schema invalido |

## Politica de retencao

Registros de auditoria expiram apos 90 dias via TTL no DynamoDB. O campo `expiresAt` (epoch seconds) e calculado no momento da insercao por `common.utils.utcnow_plus_days_epoch(90)`. Apos expiracao, o DynamoDB remove automaticamente os registros sem custo adicional de armazenamento.

## Mudancas recentes

- Removido ramo de desembrulhamento de notificacao SNS (codigo morto, a arquitetura atual usa S3 -> SQS direta).
- Uso de `common.sns.publish_error()` em vez de try/except inline.
- Adicionado `batchItemFailures` para erros de parse do record SQS.
- Adicionado campo `expiresAt` (TTL de 90 dias) nos registros de auditoria.
