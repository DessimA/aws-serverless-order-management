# Modulo `src/common/`

## Finalidade

Modulo compartilhado com utilitários reutilizáveis por todas as Lambdas do projeto. Elimina duplicação de codigo entre as funções.

## Arquivos

### `auth.py`
Funções `hash_password()`, `verify_password()`, `create_jwt()` e `decode_jwt()` para autenticação de clientes. Implementa PBKDF2-SHA256 com salt de 16 bytes para hash de senha e JWT HS256 manual para tokens de acesso. Nao possui dependencias externas a biblioteca padrão do Python. Desenhado para ser reutilizado por outras Lambdas que precisem validar tokens.

### `sqs.py`
Funções `parse_body()` e `parse_detail()` para extrair seguramente o envelope e o detail de records SQS. Trata tanto string JSON quanto dict ja parseado. `parse_body()` deve ser usado por toda Lambda que recebe mensagens SQS, independentemente de a fila ser alimentada diretamente (S3, API) ou via EventBridge, mantendo um único ponto de leitura de body em todo o projeto.

### `http.py`
Funções `api_response()` e `error_response()` que geram respostas padronizadas com headers CORS (`Access-Control-Allow-Origin: *`). Todas as Lambdas com integração via API Gateway utilizam estas funções, garantindo consistência nos headers.

### `sns.py`
Função `publish_error()` que centraliza a lógica de publicação de alertas SNS com tratamento de erro interno (try/except). Usada por `order_validator`, `batch_processor`, `order_processor` e `lifecycle_ops`.

### `utils.py`
Utilitários gerais do projeto.

#### `utcnow_iso()`
Retorna o timestamp atual em formato ISO 8601 com sufixo `Z`.

#### `utcnow_plus_days_epoch(days)`
Retorna o timestamp epoch (segundos) para `days` dias no futuro. Usado para TTL no DynamoDB.

#### `log_event(stage, pedido_id, message)`
Função de logging estruturado que produz uma linha JSON com `stage`, `pedidoId`, `message` e `timestamp`. Substitui `print()` de payloads completos nas Lambdas. Permite correlacionar a jornada de um pedido atraves de múltiplas Lambdas via CloudWatch Logs Insights (ver `docs/observability.md`).

### Convenção de logging
Nenhuma Lambda deve logar o payload completo do evento (`json.dumps(event)`) em mensagens de sucesso/info. Apenas campos relevantes são logados (quantidade de records, pedidoId). Logs de erro (blocos `except`) podem continuar detalhados por ocorrerem com baixa frequência.

## Motivação do padrão

O padrão de modulo compartilhado (`common/`) foi adotado porque:

1. Todas as oito Lambdas dependem de common.http e/ou common.sns.
2. Antes da centralização, cada Lambda reimplementava headers CORS com pequenas variações, dificultando manutenção.
3. A função `parse_detail` corrige um bug crítico onde `json.loads()` era chamado em um objeto dict, causando `TypeError`.
4. O custo de incluir o diretorio `common/` em todos os zips de deploy e minimo (~1KB) comparado ao ganho de consistência.
