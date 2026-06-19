let lastOrderId = '';

document.addEventListener('DOMContentLoaded', () => {
    document.querySelectorAll('.tab').forEach(tab => {
        tab.addEventListener('click', () => {
            document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
            document.querySelectorAll('.tab-content').forEach(p => p.classList.remove('active'));
            tab.classList.add('active');
            document.getElementById('tab-' + tab.dataset.tab).classList.add('active');
            onTabSwitch(tab.dataset.tab);
        });
    });

    updateLastOrderDisplay();
});

function switchTab(tabId) {
    const tab = document.querySelector(`.tab[data-tab="${tabId}"]`);
    if (tab) tab.click();
}

function onTabSwitch(tabId) {
    if (tabId === 'consult' || tabId === 'manage') {
        const target = document.getElementById(tabId === 'manage' ? 'lifecycleOrderId' : 'readOrderId');
        if (lastOrderId && !target.value) {
            target.value = lastOrderId;
        }
    }
}

// ===== Helpers =====

function now() {
    return new Date().toLocaleTimeString('pt-BR', { hour12: false });
}

function escapeHtml(text) {
    if (!text) return '';
    return String(text).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function safeParseJSON(str, fallback) {
    try { return JSON.parse(str); } catch (e) { return fallback; }
}

// ===== Loading State =====

function setLoading(btnId, loading) {
    const btn = document.getElementById(btnId);
    if (!btn) return;
    if (loading) {
        btn.classList.add('btn-loading');
        btn.disabled = true;
    } else {
        btn.classList.remove('btn-loading');
        btn.disabled = false;
    }
}

// ===== Inline Results =====

function showInlineResult(tab, type, label, data, detail) {
    const card = document.getElementById('result-' + tab);
    if (!card) return;

    const statusClass = type === 'pass' ? 'status-pass' : type === 'fail' ? 'status-fail' : 'status-warn';
    const cardClass = type === 'pass' ? 'result-pass' : type === 'fail' ? 'result-fail' : 'result-warn';
    const statusText = type === 'pass' ? 'SUCESSO' : type === 'fail' ? 'ERRO' : 'AVISO';

    const body = data ? escapeHtml(JSON.stringify(data, null, 2)) : '';

    let summaryHtml = '';
    if (detail) {
        summaryHtml = '<div class="result-summary">';
        for (const [key, val] of Object.entries(detail)) {
            summaryHtml += `<div class="field"><div class="field-label">${key}</div><div class="field-value">${escapeHtml(String(val))}</div></div>`;
        }
        summaryHtml += '</div>';
    }

    card.className = 'result-card ' + cardClass;
    card.innerHTML = `
        <div class="result-label">${escapeHtml(label)}</div>
        <div class="result-timestamp">${now()}</div>
        <span class="result-status ${statusClass}">${statusText}</span>
        ${summaryHtml}
        ${body ? `<div class="result-body">${body}</div>` : ''}
    `;
}

function resetInlineResult(tab, placeholder) {
    const card = document.getElementById('result-' + tab);
    if (!card) return;
    card.className = 'result-card result-empty';
    card.innerHTML = `<div class="result-placeholder">${placeholder}</div>`;
}

// ===== Log Panel =====

function log(type, label, message) {
    const container = document.getElementById('logContainer');
    const empty = container.querySelector('.log-empty');
    if (empty) empty.remove();

    const entry = document.createElement('div');
    entry.className = 'log-entry log-' + type;
    entry.innerHTML = `<span class="log-time">[${now()}]</span> <span class="log-label">${escapeHtml(label)}</span><div class="log-body">${escapeHtml(message)}</div>`;
    container.prepend(entry);
}

function logResponse(type, label, response) {
    const msg = `Status: ${response.status}\nBody: ${JSON.stringify(response.data, null, 2)}`;
    log(type, label, msg);
}

function clearLog() {
    document.getElementById('logContainer').innerHTML = '<p class="log-empty">Clique em qualquer ação para começar.</p>';
    resetInlineResult('create', 'Preencha o formulário e clique em <strong>Criar Pedido</strong>.');
    resetInlineResult('consult', 'Digite um Order ID e clique em <strong>Consultar</strong>.');
    resetInlineResult('manage', 'Digite um Order ID e clique em <strong>Cancelar</strong> ou <strong>Atualizar</strong>.');
    resetInlineResult('batch', 'Clique em <strong>Upload Lote Válido</strong> para enviar um arquivo de teste.');
}

// ===== Last Order Badge =====

function updateLastOrderDisplay() {
    const badge = document.getElementById('lastOrderBadge');
    const display = document.getElementById('lastOrderDisplay');
    if (!badge || !display) return;
    if (lastOrderId) {
        display.textContent = lastOrderId;
        badge.style.display = 'inline';
    } else {
        badge.style.display = 'none';
    }
}

// ===== HTTP =====

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

// ===== TAB 1: CRIAR PEDIDO =====

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

async function testAPI(scenario) {
    const payload = buildOrderPayload(scenario);
    const labels = {
        'valid': 'Criar Pedido',
        'missing-pedido': 'Faltando pedidoId',
        'missing-cliente': 'Faltando clienteId',
        'invalid-json': 'JSON Inválido',
        'duplicate': 'Enviar Duplicata'
    };
    const label = 'API: ' + labels[scenario];

    if (scenario === 'valid') {
        setLoading('btnCreateOrder', true);
    }
    log('warn', label, 'Enviando payload...');

    const res = await apiPost(API_ENDPOINT, payload);

    if (scenario === 'valid') {
        setLoading('btnCreateOrder', false);
    }

    if (scenario === 'valid' && res.status === 200) {
        lastOrderId = payload.pedidoId;
        updateLastOrderDisplay();
        showInlineResult('create', 'pass', label, res.data, {
            'pedidoId': payload.pedidoId,
            'Status HTTP': res.status,
            'clienteId': payload.clienteId,
            'Itens': (payload.itens || []).length + ' ite' + ((payload.itens || []).length === 1 ? 'm' : 'ns')
        });
        logResponse('pass', label, res);
    } else if ((scenario === 'missing-pedido' || scenario === 'missing-cliente' || scenario === 'invalid-json') && res.status === 400) {
        showInlineResult('create', 'pass', label + ' (400 esperado)', res.data);
        logResponse('pass', label + ' (expected 400)', res);
    } else if (scenario === 'duplicate') {
        if (res.status === 200) {
            showInlineResult('create', 'warn', label + ' (aceito, falhará no processador)', res.data);
            logResponse('pass', label + ' (accepted, will fail at processor)', res);
        } else {
            showInlineResult('create', 'warn', label, res.data);
            logResponse('warn', label, res);
        }
    } else if (res.status === 200) {
        showInlineResult('create', 'pass', label, res.data);
        logResponse('pass', label, res);
    } else {
        showInlineResult('create', 'fail', label, res.data);
        logResponse('fail', label, res);
    }
}

// ===== TAB 2: CONSULTAR PEDIDO =====

async function testRead(scenario) {
    const orderId = scenario === 'valid'
        ? (document.getElementById('readOrderId').value.trim() || lastOrderId || 'ORD-TEST-001')
        : 'ORD-NONEXISTENT-' + Date.now();

    const label = scenario === 'valid' ? 'Consultar Pedido' : 'Consultar Inexistente';

    setLoading('btnReadOrder', true);
    log('warn', 'Read: ' + label, `Buscando ${orderId}...`);

    const url = READ_ENDPOINT.replace('{orderId}', encodeURIComponent(orderId));
    const res = await apiGet(url);

    setLoading('btnReadOrder', false);

    if (scenario === 'valid' && res.status === 200) {
        const order = res.data;
        const detail = {
            'Order ID': order.orderId || orderId,
            'Status': order.status || order.Status || '—',
            'Cliente': order.clienteId || order.cliente_id || '—',
        };
        const itemCount = (order.itens || order.Items || []).length;
        if (itemCount) detail['Itens'] = itemCount;

        showInlineResult('consult', 'pass', label, res.data, detail);
        logResponse('pass', 'Read: ' + label, res);
        document.getElementById('consult-actions').style.display = 'flex';
    } else if (scenario === 'nonexistent' && res.status === 404) {
        showInlineResult('consult', 'pass', label + ' (404 esperado)', res.data);
        logResponse('pass', 'Read: ' + label + ' (expected 404)', res);
        document.getElementById('consult-actions').style.display = 'none';
    } else if (res.status === 200) {
        showInlineResult('consult', 'pass', label, res.data);
        logResponse('pass', 'Read: ' + label, res);
    } else {
        showInlineResult('consult', 'fail', label, res.data);
        logResponse('fail', 'Read: ' + label, res);
        document.getElementById('consult-actions').style.display = 'none';
    }
}

// ===== TAB 3: GERENCIAR PEDIDO =====

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
        'cancel': 'Cancelar Pedido',
        'cancel-nonexistent': 'Cancelar Inexistente',
        'update': 'Atualizar Pedido',
        'update-nonexistent': 'Atualizar Inexistente'
    };
    const label = 'Lifecycle: ' + labels[scenario];

    log('warn', label, `Publicando ${payload.detailType} no EventBridge...`);

    const res = await apiPost(TEST_ENDPOINT, payload);

    if (res.status === 200 && res.data.FailedEntryCount === 0) {
        const detail = {
            'Evento': payload.detailType,
            'Order ID': payload.detail.pedidoId,
            'FailedEntryCount': 0
        };
        if (scenario.includes('nonexistent')) {
            showInlineResult('manage', 'warn', label + ' (evento publicado, mas falhará no processador)', res.data, detail);
        } else {
            showInlineResult('manage', 'pass', label, res.data, detail);
        }
        logResponse('pass', label + ' (event published)', res);
    } else if (res.status === 200) {
        showInlineResult('manage', 'warn', label + ' (falha parcial)', res.data);
        logResponse('warn', label + ' (some entries failed)', res);
    } else {
        showInlineResult('manage', 'fail', label, res.data);
        logResponse('fail', label, res);
    }
}

// ===== TAB 4: UPLOAD EM LOTE =====

function buildS3Payload(scenario) {
    const baseFilename = document.getElementById('s3Filename').value.trim() || 'pedidos_lote_';
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
                content: { wrong_key: 'Isto vai disparar um alerta SNS porque lista_pedidos está faltando' },
                contentType: 'application/json'
            };
        case 'corrupt':
            return {
                action: 'upload_file',
                filename: `${baseFilename}${ts}.txt`,
                content: 'Este não é um arquivo JSON, vai falhar ao fazer parse e disparar um alerta SNS.',
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
        'valid': 'Upload Lote Válido',
        'invalid-schema': 'Schema Inválido (→ Alerta SNS)',
        'corrupt': 'Arquivo Corrompido (→ Alerta SNS)',
        'list': 'Listar Arquivos'
    };
    const label = 'S3: ' + labels[scenario];

    if (scenario === 'list') {
        log('warn', label, 'Buscando lista de arquivos...');
    } else {
        log('warn', label, `Enviando ${payload.filename}...`);
    }

    const res = await apiPost(TEST_ENDPOINT, payload);

    if (res.status === 200) {
        if (scenario === 'valid') {
            showInlineResult('batch', 'pass', label, res.data, { 'Arquivo': payload.filename, 'Status HTTP': res.status });
        } else if (scenario === 'list') {
            const files = res.data.files || res.data.arquivos || [];
            const detail = { 'Arquivos encontrados': files.length };
            showInlineResult('batch', 'pass', label, res.data, detail);
        } else {
            showInlineResult('batch', 'pass', label + ' (arquivo enviado, aguardando processamento)', res.data);
        }
        logResponse('pass', label, res);
    } else {
        showInlineResult('batch', 'fail', label, res.data);
        logResponse('fail', label, res);
    }
}
