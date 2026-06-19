# Lambda `test_controller` (`src/test_controller/index.py`)

## Finalidade

Controlador de testes interno (rota `POST /test`). Orquestra tres acoes para validacao dos fluxos do sistema.

## Acoes

### `publish_event`
Publica eventos de ciclo de vida (`OrderCancelled` / `OrderUpdated`) diretamente no EventBridge, permitindo testar os fluxos de cancelamento e atualizacao sem dependencia do frontend.

### `upload_file`
Faz upload de conteudo para o bucket S3 de dados, acionando o `batch_processor` para validacao e auditoria.

### `list_files`
Lista arquivos no bucket S3 com paginacao completa. Percorre todas as paginas usando `ContinuationToken` para garantir que todos os objetos sejam retornados, mesmo em buckets com mais de 1000 objetos.

## Ambiente

| Variavel | Descricao |
|----------|-----------|
| `EVENT_BUS_NAME` | Nome do barramento de eventos |
| `S3_BUCKET` | Nome do bucket S3 de dados |

## Mudancas recentes

- `handle_list_files` agora implementa paginacao com loop `while IsTruncated`.
- Uso de `common.http.api_response()` e `error_response()`.
