let lastOrderId = '';

document.addEventListener('DOMContentLoaded', () => {
    document.querySelectorAll('.tab').forEach(tab => {
        tab.addEventListener('click', () => {
            document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
            document.querySelectorAll('.tab-content').forEach(p => p.classList.remove('active'));
            tab.classList.add('active');
            document.getElementById('tab-' + tab.dataset.tab).classList.add('active');

            if (tab.dataset.tab === 'lifecycle' || tab.dataset.tab === 'read') {
                const src = tab.dataset.tab === 'lifecycle' ? 'apiPedidoId' : 'apiPedidoId';
                const target = tab.dataset.tab === 'lifecycle' ? 'lifecycleOrderId' : 'readOrderId';
                const val = document.getElementById(src).value;
                if (val && !document.getElementById(target).value) {
                    document.getElementById(target).value = val;
                }
            }
        });
    });

    document.getElementById('lifecycleOrderId').addEventListener('input', function() {
        document.getElementById('updateItensGroup').style.display = this.value ? 'block' : 'none';
    });
});

function now() {
    return new Date().toLocaleTimeString('pt-BR', { hour12: false });
}

function log(type, label, message) {
    const container = document.getElementById('logContainer');
    const empty = container.querySelector('.log-empty');
    if (empty) empty.remove();

    const entry = document.createElement('div');
    entry.className = 'log-entry log-' + type;
    entry.innerHTML = `<span class="log-time">[${now()}]</span> <span class="log-label">${label}</span><div class="log-body">${message}</div>`;
    container.prepend(entry);
}

function clearLog() {
    document.getElementById('logContainer').innerHTML = '<p class="log-empty">Click any test button to start</p>';
}

function logResponse(type, label, response) {
    const msg = `Status: ${response.status}<br>Body: ${escapeHtml(JSON.stringify(response.data, null, 2))}`;
    log(type, label, msg);
}

function escapeHtml(text) {
    if (!text) return '';
    return String(text).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

async function apiPost(url, body) {
    try {
        const res = await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body)
        });
        const data = await res.json().catch(() => ({ raw: 'Could not parse response' }));
        return { status: res.status, data };
    } catch (err) {
        return { status: 0, data: { error: err.message || 'Network error' } };
    }
}

async function apiGet(url) {
    try {
        const res = await fetch(url);
        const data = await res.json().catch(() => ({ raw: 'Could not parse response' }));
        return { status: res.status, data };
    } catch (err) {
        return { status: 0, data: { error: err.message || 'Network error' } };
    }
}

function buildOrderPayload(scenario) {
    let pedidoId = document.getElementById('apiPedidoId').value.trim();
    let clienteId = document.getElementById('apiClienteId').value.trim();
    let itensRaw = document.getElementById('apiItens').value.trim();

    if (!pedidoId) pedidoId = 'ORD-TEST-' + Date.now();
    if (!clienteId) clienteId = 'CLI-TEST';

    switch (scenario) {
        case 'valid':
            if (!pedidoId.includes('{{timestamp}}')) {
                pedidoId = pedidoId + '-' + Date.now();
            }
            return { pedidoId, clienteId, itens: safeParseJSON(itensRaw, []) };
        case 'missing-pedido':
            return { clienteId, itens: safeParseJSON(itensRaw, []) };
        case 'missing-cliente':
            return { pedidoId, itens: safeParseJSON(itensRaw, []) };
        case 'invalid-json':
            return 'this is not valid json at all!!!';
        case 'duplicate':
            return { pedidoId: lastOrderId || (pedidoId + '-' + Date.now()), clienteId, itens: safeParseJSON(itensRaw, []) };
        default:
            return { pedidoId, clienteId, itens: safeParseJSON(itensRaw, []) };
    }
}

function safeParseJSON(str, fallback) {
    try { return JSON.parse(str); } catch (e) { return fallback; }
}

async function testAPI(scenario) {
    const payload = buildOrderPayload(scenario);
    const labels = {
        'valid': 'API: Send Valid Order',
        'missing-pedido': 'API: Missing pedidoId',
        'missing-cliente': 'API: Missing clienteId',
        'invalid-json': 'API: Invalid JSON',
        'duplicate': 'API: Send Duplicate'
    };

    log('warn', labels[scenario], `Sending payload...`);

    const res = await apiPost(API_ENDPOINT, payload);

    if (scenario === 'valid' && res.status === 200) {
        lastOrderId = payload.pedidoId;
        logResponse('pass', labels[scenario], res);
    } else if ((scenario === 'missing-pedido' || scenario === 'missing-cliente' || scenario === 'invalid-json') && res.status === 400) {
        logResponse('pass', labels[scenario] + ' (expected 400)', res);
    } else if (scenario === 'duplicate') {
        if (res.status === 200) {
            logResponse('pass', labels[scenario] + ' (accepted, will fail at processor with ConditionalCheckFailedException → DLQ)', res);
        } else {
            logResponse('warn', labels[scenario], res);
        }
    } else if (res.status === 200) {
        logResponse('pass', labels[scenario], res);
    } else {
        logResponse('fail', labels[scenario], res);
    }
}

function buildS3Payload(scenario) {
    const baseFilename = document.getElementById('s3Filename').value.trim() || 'test_pedidos_';
    const ts = Date.now();
    const filename = `${baseFilename}${ts}.json`;

    switch (scenario) {
        case 'valid':
            return {
                action: 'upload_file',
                filename,
                content: {
                    lista_pedidos: [
                        { id_pedido_arquivo: `S3-BATCH-${ts}`, id_cliente_arquivo: 'CORP-USR-01', itens_pedido_arquivo: [{ sku: 'AWS-VOUCHER-PRO', qtd: 5 }] }
                    ]
                },
                contentType: 'application/json'
            };
        case 'invalid-schema':
            return {
                action: 'upload_file',
                filename,
                content: { wrong_key: 'This will trigger an SNS alert because lista_pedidos is missing' },
                contentType: 'application/json'
            };
        case 'corrupt':
            return {
                action: 'upload_file',
                filename: `${baseFilename}${ts}.txt`,
                content: 'This is not a JSON file at all, it will fail to parse and trigger an SNS alert.',
                contentType: 'text/plain'
            };
        case 'list':
            return { action: 'list_files', prefix: baseFilename };
        default:
            return { action: 'upload_file', filename, content: {} };
    }
}

async function testS3(scenario) {
    const payload = buildS3Payload(scenario);
    const labels = {
        'valid': 'S3: Upload Valid Batch',
        'invalid-schema': 'S3: Upload Invalid Schema (→ SNS Alert)',
        'corrupt': 'S3: Upload Corrupt File (→ SNS Alert)',
        'list': 'S3: List Files'
    };

    if (scenario === 'list') {
        log('warn', labels[scenario], 'Fetching file list...');
    } else {
        log('warn', labels[scenario], `Uploading ${payload.filename}...`);
    }

    const res = await apiPost(TEST_ENDPOINT, payload);

    if (res.status === 200) {
        if (scenario === 'valid' || scenario === 'invalid-schema' || scenario === 'corrupt') {
            logResponse('pass', labels[scenario] + ' (file uploaded, waiting for file_validator processing...)', res);
        } else {
            logResponse('pass', labels[scenario], res);
        }
    } else {
        logResponse('fail', labels[scenario], res);
    }
}

function buildLifecyclePayload(scenario) {
    const orderId = document.getElementById('lifecycleOrderId').value.trim() || 'ORD-NONEXISTENT-' + Date.now();
    const itensRaw = document.getElementById('updateItens').value.trim();

    switch (scenario) {
        case 'cancel':
            return { action: 'publish_event', detailType: 'OrderCancelled', detail: { pedidoId: orderId } };
        case 'cancel-nonexistent':
            return { action: 'publish_event', detailType: 'OrderCancelled', detail: { pedidoId: 'ORD-NONEXISTENT-' + Date.now() } };
        case 'update':
            return { action: 'publish_event', detailType: 'OrderUpdated', detail: { pedidoId: orderId, novosItens: safeParseJSON(itensRaw, []) } };
        case 'update-nonexistent':
            return { action: 'publish_event', detailType: 'OrderUpdated', detail: { pedidoId: 'ORD-NONEXISTENT-' + Date.now(), novosItens: [{ nome: 'Ghost Item', quantidade: 1 }] } };
        default:
            return { action: 'publish_event', detailType: 'OrderCancelled', detail: { pedidoId: orderId } };
    }
}

async function testLifecycle(scenario) {
    const payload = buildLifecyclePayload(scenario);
    const labels = {
        'cancel': 'Lifecycle: Cancel Order',
        'cancel-nonexistent': 'Lifecycle: Cancel Non-existent (→ DLQ)',
        'update': 'Lifecycle: Update Order',
        'update-nonexistent': 'Lifecycle: Update Non-existent (→ DLQ)'
    };

    log('warn', labels[scenario], `Publishing ${payload.detailType} to EventBridge...`);

    const res = await apiPost(TEST_ENDPOINT, payload);

    if (res.status === 200 && res.data.FailedEntryCount === 0) {
        const extra = scenario.includes('nonexistent')
            ? ' (event published, but lifecycle processor will fail with ConditionalCheckFailedException → DLQ)'
            : ' (event published, processing via SQS FIFO + Lifecycle Lambda...)';
        logResponse('pass', labels[scenario] + extra, res);
    } else if (res.status === 200) {
        logResponse('warn', labels[scenario] + ' (some entries failed)', res);
    } else {
        logResponse('fail', labels[scenario], res);
    }
}

async function testRead(scenario) {
    const orderId = scenario === 'valid'
        ? (document.getElementById('readOrderId').value.trim() || lastOrderId || 'ORD-TEST-001')
        : 'ORD-NONEXISTENT-' + Date.now();

    const label = scenario === 'valid' ? 'Read: Get Order' : 'Read: Get Non-existent Order';

    log('warn', label, `Fetching ${orderId}...`);

    const url = READ_ENDPOINT.replace('{orderId}', encodeURIComponent(orderId));
    const res = await apiGet(url);

    if (scenario === 'valid' && res.status === 200) {
        logResponse('pass', label, res);
        document.getElementById('readResult').style.display = 'block';
        document.getElementById('readResultContent').textContent = JSON.stringify(res.data, null, 2);
    } else if (scenario === 'nonexistent' && res.status === 404) {
        logResponse('pass', label + ' (expected 404)', res);
    } else if (res.status === 200) {
        logResponse('pass', label, res);
    } else {
        logResponse('fail', label, res);
    }
}
