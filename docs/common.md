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
Utilitarios gerais (quando aplicavel).

## Motivacao do padrao

O padrao de modulo compartilhado (`common/`) foi adotado porque:

1. Seis das oito Lambdas precisam de logica de resposta HTTP e/ou publicacao SNS.
2. Antes da centralizacao, cada Lambda reimplementava headers CORS com pequenas variacoes, dificultando manutencao.
3. A funcao `parse_detail` corrige um bug critico onde `json.loads()` era chamado em um objeto dict, causando `TypeError`.
4. O custo de incluir o diretorio `common/` em todos os zips de deploy e minimo (~1KB) comparado ao ganho de consistencia.
