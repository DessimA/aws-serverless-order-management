# Modulo `src/common/`

## Finalidade

Modulo compartilhado com utilitarios reutilizaveis por todas as Lambdas do projeto. Elimina duplicacao de codigo entre as funcoes.

## Arquivos

### `sqs.py`
Funcoes `parse_body()` e `parse_detail()` para extrair seguramente o envelope e o detail de records SQS. Trata tanto o caso de `detail` como string JSON quanto como objeto dict (comportamento real do EventBridge ao entregar para SQS).

### `http.py`
Funcoes `api_response()` e `error_response()` que geram respostas padronizadas com headers CORS (`Access-Control-Allow-Origin: *`). Todas as Lambdas com integracao via API Gateway utilizam estas funcoes, garantindo consistencia nos headers.

### `sns.py`
Funcao `publish_error()` que centraliza a logica de publicacao de alertas SNS com tratamento de erro interno (try/except). Usada por `order_validator`, `batch_processor`, `order_processor` e `lifecycle_ops`.

### `utils.py`
Utilitarios gerais do projeto.

#### `utcnow_iso()`
Retorna o timestamp atual em formato ISO 8601 com sufixo `Z`.

#### `utcnow_plus_days_epoch(days)`
Retorna o timestamp epoch (segundos) para `days` dias no futuro. Usado para TTL no DynamoDB.

#### `log_event(stage, pedido_id, message)`
Funcao de logging estruturado que produz uma linha JSON com `stage`, `pedidoId`, `message` e `timestamp`. Substitui `print()` de payloads completos nas Lambdas. Permite correlacionar a jornada de um pedido atraves de múltiplas Lambdas via CloudWatch Logs Insights (ver `docs/observability.md`).

### Convencao de logging
A partir da Rodada 5, nenhuma Lambda deve logar o payload completo do evento (`json.dumps(event)`) em mensagens de sucesso/info. Apenas campos relevantes sao logados (quantidade de records, pedidoId). Logs de erro (blocos `except`) podem continuar detalhados por ocorrerem com baixa frequencia.

## Motivacao do padrao

O padrao de modulo compartilhado (`common/`) foi adotado porque:

1. Todas as oito Lambdas dependem de common.http e/ou common.sns.
2. Antes da centralizacao, cada Lambda reimplementava headers CORS com pequenas variacoes, dificultando manutencao.
3. A funcao `parse_detail` corrige um bug critico onde `json.loads()` era chamado em um objeto dict, causando `TypeError`.
4. O custo de incluir o diretorio `common/` em todos os zips de deploy e minimo (~1KB) comparado ao ganho de consistencia.
