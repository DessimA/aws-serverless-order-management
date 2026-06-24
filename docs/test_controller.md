# Lambda `test_controller` (`src/test_controller/index.py`)

## Finalidade

Controlador de testes interno (rota `POST /test`). Orquestra tres ações para validação dos fluxos do sistema.

## Ações

### `publish_event`
Publica eventos de ciclo de vida (`OrderCancelled` / `OrderUpdated`) diretamente no EventBridge, permitindo testar os fluxos de cancelamento e atualização sem dependência do frontend.

Aceita apenas os `detailType` listados em `ALLOWED_DETAIL_TYPES` no codigo. Qualquer outro detailType retorna `400 Bad Request`.

### `upload_file`
Faz upload de conteúdo para o bucket S3 de dados, acionando o `batch_processor` para validação e auditoria.

### `list_files`
Lista arquivos no bucket S3 com páginação completa. Percorre todas as páginas usando `ContinuationToken` para garantir que todos os objetos sejam retornados, mesmo em buckets com mais de 1000 objetos.

Todas as respostas usam `common.http.api_response()` e `error_response()`.

## Ambiente

| Variável | Descrição |
|----------|-----------|
| `EVENT_BUS_NAME` | Nome do barramento de eventos |
| `S3_BUCKET` | Nome do bucket S3 de dados |

