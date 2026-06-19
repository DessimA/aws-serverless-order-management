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

## Mudancas recentes

- Removido ramo de desembrulhamento de notificacao SNS (codigo morto, a arquitetura atual usa S3 -> SQS direta).
- Uso de `common.sns.publish_error()` em vez de try/except inline.
- Adicionado `batchItemFailures` para erros de parse do record SQS.
