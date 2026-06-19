# Frontend (`frontend/app.js`)

## Finalidade

Dashboard de testes servido como S3 Static Website. Interface com abas para testar todos os fluxos do sistema.

## Mudancas recentes

### Cenario "Enviar Duplicata"

A funcao `buildOrderPayload()` no cenario `duplicate` agora reutiliza `lastOrderId` em vez de gerar um ID novo:

```javascript
if (scenario === 'duplicate') {
    const id = lastOrderId || 'ORD-TEST-DUP';
    return { pedidoId: id, clienteId: 'CLI-DUP-001', itens: [{ sku: 'PROD-DUP', qtd: 1 }] };
}
```

Isso permite que o mesmo pedidoId seja reenviado e exercite de fato a `ConditionExpression: attribute_not_exists(orderId)` no `order_processor`, gerando o alerta SNS de duplicata.
