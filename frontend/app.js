let lastOrderId = '';
let lastReadOrder = null;

document.addEventListener('DOMContentLoaded', () => {
    const envBadge = document.getElementById('envBadge');
    if (envBadge && typeof AWS_REGION !== 'undefined') {
        envBadge.textContent = AWS_REGION;
    }

    document.querySelectorAll('button[data-bs-toggle="tab"]').forEach(tab => {
        tab.addEventListener('shown.bs.tab', e => {
            const id = e.target.getAttribute('data-bs-target').replace('#tab-', '');
            onTabSwitch(id);
        });
    });

    updateLastOrderDisplay();
});

function switchTab(tabId) {
    const link = document.querySelector(`button[data-bs-target="#tab-${tabId}"]`);
    if (link) {
        const tab = new bootstrap.Tab(link);
        tab.show();
    }
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

function slugify(text) {
    return text
        .normalize('NFD')
        .replace(/[\u0300-\u036f]/g, '')
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/^-|-$/g, '')
        .substring(0, 20);
}

function generateRandomOrder() {
    const clientes = ['Maria Santos', 'Carlos Oliveira', 'Ana Costa', 'Pedro Almeida', 'Juliana Lima'];
    const produtos = [
        { nome: 'Curso AWS Solutions Architect', preco: 249.90 },
        { nome: 'Curso Azure Administrator', preco: 199.90 },
        { nome: 'Curso Google Cloud Engineer', preco: 179.90 },
        { nome: 'Curso Kubernetes Fundamentals', preco: 299.90 },
        { nome: 'Curso DevOps Pipeline', preco: 349.90 }
    ];
    const c = clientes[Math.floor(Math.random() * clientes.length)];
    const p = produtos[Math.floor(Math.random() * produtos.length)];
    return { cliente: c, produto: p.nome, qtd: Math.floor(Math.random() * 3) + 1, preco: p.preco };
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

    const borderClass = type === 'pass' ? 'border-success' : type === 'fail' ? 'border-danger' : 'border-warning';
    const bgClass = type === 'pass' ? 'bg-success' : type === 'fail' ? 'bg-danger' : 'bg-warning';
    const icon = type === 'pass' ? 'check_circle' : type === 'fail' ? 'error' : 'warning';
    const statusText = type === 'pass' ? 'Sucesso' : type === 'fail' ? 'Erro' : 'Aviso';

    card.className = 'card ' + borderClass;
    card.style.background = type === 'pass'
        ? 'rgba(var(--bs-success-rgb), 0.05)'
        : type === 'fail'
            ? 'rgba(var(--bs-danger-rgb), 0.05)'
            : 'rgba(var(--bs-warning-rgb), 0.05)';

    let summaryHtml = '';
    if (detail) {
        summaryHtml = '<div class="result-summary">';
        for (const [key, val] of Object.entries(detail)) {
            summaryHtml += `<div class="field"><div class="field-label">${escapeHtml(key)}</div><div class="field-value">${escapeHtml(String(val))}</div></div>`;
        }
        summaryHtml += '</div>';
    }

    const body = data ? escapeHtml(JSON.stringify(data, null, 2)) : '';

    card.innerHTML = `
        <div class="card-body">
            <div class="d-flex align-items-center gap-2 mb-2">
                <span class="material-icons ${bgClass} bg-opacity-10 p-1 rounded" style="font-size:1.1rem;">${icon}</span>
                <span class="fw-semibold small">${escapeHtml(statusText)}</span>
                <span class="text-secondary small ms-auto">${now()}</span>
            </div>
            <div class="fw-semibold small mb-2">${escapeHtml(label)}</div>
            ${summaryHtml}
            ${body ? `<div class="result-body">${body}</div>` : ''}
        </div>
    `;
}

function resetInlineResult(tab, placeholder) {
    const card = document.getElementById('result-' + tab);
    if (!card) return;
    card.className = 'card border-secondary bg-transparent';
    card.innerHTML = `
        <div class="card-body text-center text-secondary small">
            <span class="material-icons fs-3 mb-1 d-block">info</span>
            ${placeholder}
        </div>
    `;
}

// ===== Log Panel =====

function log(type, label, message) {
    const container = document.getElementById('logContainer');
    if (!container) return;
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
    const container = document.getElementById('logContainer');
    if (container) {
        container.innerHTML = '<p class="text-center text-secondary small py-4 mb-0 log-empty">Clique em qualquer acao para comecar.</p>';
    }
    resetInlineResult('create', 'Preencha os campos e clique em <strong>Criar Pedido</strong>.');
    resetInlineResult('consult', 'Digite um Order ID e clique em <strong>Consultar</strong>.');
    resetInlineResult('manage', 'Digite um Order ID e clique em <strong>Cancelar</strong> ou <strong>Atualizar</strong>.');
    resetInlineResult('batch', 'Clique em <strong>Gerar e Enviar Lote de Teste</strong>.');
}

// ===== Last Order Badge =====

function updateLastOrderDisplay() {
    const badge = document.getElementById('lastOrderBadge');
    const display = document.getElementById('lastOrderDisplay');
    if (!badge || !display) return;
    if (lastOrderId) {
        display.textContent = lastOrderId;
        badge.classList.remove('d-none');
    } else {
        badge.classList.add('d-none');
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

// ===== TAB 1: NOVO PEDIDO =====

function buildOrderFromForm(scenario) {
    if (scenario === 'auto') {
        const r = generateRandomOrder();
        document.getElementById('createCliente').value = r.cliente;
        document.getElementById('createProduto').value = r.produto;
        document.getElementById('createQtd').value = r.qtd;
        document.getElementById('createPreco').value = r.preco;
    }

    const clienteNome = document.getElementById('createCliente').value.trim() || 'Cliente Teste';
    const produtoNome = document.getElementById('createProduto').value.trim() || 'Produto Teste';
    const qtd = parseInt(document.getElementById('createQtd').value, 10) || 1;
    const preco = parseFloat(document.getElementById('createPreco').value) || 99.90;

    const pedidoId = 'ORD-' + Date.now();
    const clienteId = 'CLI-' + slugify(clienteNome) + '-' + Math.floor(Math.random() * 1000);

    return {
        pedidoId,
        clienteId,
        itens: [{ nome: produtoNome, quantidade: qtd, preco: preco }]
    };
}

async function testAPI(scenario) {
    scenario = scenario || 'valid';

    if (scenario === 'valid' || scenario === 'auto') {
        const payload = buildOrderFromForm(scenario);

        if (scenario !== 'auto') {
            setLoading('btnCreateOrder', true);
        }

        log('warn', 'Novo Pedido: ' + (scenario === 'auto' ? 'Automatico' : 'Criar Pedido'), 'Enviando pedido...');

        const res = await apiPost(API_ENDPOINT, payload);
        setLoading('btnCreateOrder', false);

        if (res.status === 200) {
            lastOrderId = payload.pedidoId;
            updateLastOrderDisplay();
            const itens = payload.itens || [];
            const itemDesc = itens.map(i => i.nome + ' (' + i.quantidade + 'x R$ ' + i.preco.toFixed(2) + ')').join(', ');
            showInlineResult('create', 'pass', 'Pedido criado com sucesso', res.data, {
                'Pedido': payload.pedidoId,
                'Cliente': payload.clienteId,
                'Itens': itemDesc
            });
            logResponse('pass', 'Novo Pedido: Pedido criado', res);
        } else {
            showInlineResult('create', 'fail', 'Falha ao criar pedido', res.data, {
                'Status HTTP': res.status
            });
            logResponse('fail', 'Novo Pedido: Falha', res);
        }
        return;
    }

    // Error scenarios (same as before)
    const payload = buildLegacyErrorPayload(scenario);
    const labels = {
        'missing-pedido': 'Faltando pedidoId',
        'missing-cliente': 'Faltando clienteId',
        'invalid-json': 'JSON Invalido',
        'duplicate': 'Enviar Duplicata'
    };
    const label = 'Novo Pedido: ' + labels[scenario];

    log('warn', label, 'Enviando payload de erro...');
    const res = await apiPost(API_ENDPOINT, payload);

    if ((scenario === 'missing-pedido' || scenario === 'missing-cliente' || scenario === 'invalid-json') && res.status === 400) {
        showInlineResult('create', 'pass', label + ' (400 esperado)', res.data);
        logResponse('pass', label + ' (expected 400)', res);
    } else if (scenario === 'duplicate') {
        if (res.status === 200) {
            showInlineResult('create', 'warn', label + ' (aceito, falhara no processador)', res.data);
            logResponse('pass', label + ' (accepted)', res);
        } else {
            showInlineResult('create', 'warn', label, res.data);
            logResponse('warn', label, res);
        }
    } else {
        showInlineResult('create', 'fail', label, res.data);
        logResponse('fail', label, res);
    }
}

function buildLegacyErrorPayload(scenario) {
    const clienteNome = document.getElementById('createCliente')?.value?.trim() || 'Cliente Teste';
    const produtoNome = document.getElementById('createProduto')?.value?.trim() || 'Produto Teste';
    const qtd = parseInt(document.getElementById('createQtd')?.value, 10) || 1;
    const preco = parseFloat(document.getElementById('createPreco')?.value) || 99.90;
    const pedidoId = 'ORD-' + Date.now();
    const clienteId = 'CLI-' + slugify(clienteNome) + '-' + Math.floor(Math.random() * 1000);
    const itens = [{ nome: produtoNome, quantidade: qtd, preco: preco }];

    switch (scenario) {
        case 'missing-pedido':
            return { clienteId, itens };
        case 'missing-cliente':
            return { pedidoId, itens };
        case 'invalid-json':
            return 'this is not valid json at all!!!';
        case 'duplicate':
            return { pedidoId: lastOrderId || (pedidoId + '-' + Date.now()), clienteId, itens };
        default:
            return { pedidoId, clienteId, itens };
    }
}

// ===== TAB 2: CONSULTAR =====

async function testRead(scenario) {
    if (scenario === 'last') {
        if (!lastOrderId) {
            showInlineResult('consult', 'warn', 'Nenhum pedido encontrado', null, {
                'Aviso': 'Nenhum pedido foi criado nesta sessao. Crie um pedido primeiro.'
            });
            log('warn', 'Consultar: Ultimo Pedido', 'Nenhum pedido criado nesta sessao.');
            return;
        }
        document.getElementById('readOrderId').value = lastOrderId;
    }

    const orderId = scenario === 'nonexistent'
        ? 'ORD-NONEXISTENT-' + Date.now()
        : (document.getElementById('readOrderId').value.trim() || lastOrderId || 'ORD-TEST-001');

    const label = (scenario === 'last' || scenario === 'valid') ? 'Consultar Pedido' : 'Consultar Inexistente';

    setLoading('btnReadOrder', true);
    log('warn', 'Consultar: ' + label, 'Buscando ' + orderId + '...');

    const url = READ_ENDPOINT.replace('{orderId}', encodeURIComponent(orderId));
    const res = await apiGet(url);
    setLoading('btnReadOrder', false);

    if (res.status === 200) {
        const order = res.data;
        const itensList = order.itens || order.Items || [];
        const itemDesc = itensList.map(i => (i.nome || i.Nome || '') + ' x' + (i.quantidade || i.Quantidade || 0)).join(', ');
        const detail = {
            'Pedido': order.orderId || orderId,
            'Cliente': order.clienteId || order.cliente_id || '-',
            'Status': order.status || order.Status || '-',
            'Itens': itemDesc || itensList.length + ' item(ns)'
        };
        showInlineResult('consult', 'pass', label, res.data, detail);
        logResponse('pass', 'Consultar: ' + label, res);
        const actions = document.getElementById('consult-actions');
        if (actions) actions.classList.remove('d-none');
        lastReadOrder = order;
    } else if (res.status === 404) {
        showInlineResult('consult', 'pass', label + ' (404 esperado para pedido inexistente)', res.data);
        logResponse('pass', 'Consultar: ' + label + ' (expected 404)', res);
        const actions = document.getElementById('consult-actions');
        if (actions) actions.classList.add('d-none');
    } else {
        showInlineResult('consult', 'fail', label, res.data);
        logResponse('fail', 'Consultar: ' + label, res);
        const actions = document.getElementById('consult-actions');
        if (actions) actions.classList.add('d-none');
    }
}

// ===== TAB 3: GERENCIAR =====

function buildManagePayload(scenario) {
    const orderId = document.getElementById('lifecycleOrderId').value.trim() || 'ORD-NONEXISTENT-' + Date.now();

    if (scenario === 'cancel') {
        return { action: 'publish_event', detailType: 'OrderCancelled', detail: { pedidoId: orderId } };
    }
    if (scenario === 'cancel-nonexistent') {
        return { action: 'publish_event', detailType: 'OrderCancelled', detail: { pedidoId: 'ORD-NONEXISTENT-' + Date.now() } };
    }

    const produto = document.getElementById('mgmtProduto').value.trim() || 'Produto';
    const qtd = parseInt(document.getElementById('mgmtQtd').value, 10) || 1;
    const preco = parseFloat(document.getElementById('mgmtPreco').value) || 99.90;

    if (scenario === 'update') {
        return {
            action: 'publish_event',
            detailType: 'OrderUpdated',
            detail: { pedidoId: orderId, novosItens: [{ nome: produto, quantidade: qtd, preco: preco }] }
        };
    }
    // update-nonexistent
    return {
        action: 'publish_event',
        detailType: 'OrderUpdated',
        detail: { pedidoId: 'ORD-NONEXISTENT-' + Date.now(), novosItens: [{ nome: produto, quantidade: qtd, preco: preco }] }
    };
}

async function testLifecycle(scenario) {
    const payload = buildManagePayload(scenario);
    const labelMap = {
        'cancel': 'Cancelar Pedido',
        'cancel-nonexistent': 'Cancelar Inexistente',
        'update': 'Atualizar Pedido',
        'update-nonexistent': 'Atualizar Inexistente'
    };
    const label = 'Gerenciar: ' + labelMap[scenario];

    log('warn', label, 'Publicando ' + payload.detailType + ' no EventBridge...');
    const res = await apiPost(TEST_ENDPOINT, payload);

    if (res.status === 200 && (res.data.FailedEntryCount === 0 || res.data.FailedEntryCount === undefined)) {
        const detail = {
            'Evento': payload.detailType,
            'Pedido': payload.detail.pedidoId
        };
        if (scenario.includes('nonexistent')) {
            showInlineResult('manage', 'warn', label + ' (evento publicado, falhara no processador)', res.data, detail);
        } else {
            showInlineResult('manage', 'pass', label, res.data, detail);
        }
        logResponse('pass', label + ' (event published)', res);
    } else if (res.status === 200) {
        showInlineResult('manage', 'warn', label + ' (falha parcial)', res.data);
        logResponse('warn', label + ' (partial)', res);
    } else {
        showInlineResult('manage', 'fail', label, res.data);
        logResponse('fail', label, res);
    }
}

// ===== TAB 4: UPLOAD =====

function buildBatchPayload(scenario) {
    const ts = Date.now();

    if (scenario === 'list') {
        return { action: 'list_files', prefix: 'lote_' };
    }

    if (scenario === 'invalid-schema') {
        return {
            action: 'upload_file',
            filename: 'lote_invalido_' + ts + '.json',
            content: { chave_errada: 'lista_pedidos ausente — vai disparar alerta SNS' },
            contentType: 'application/json'
        };
    }

    if (scenario === 'corrupt') {
        return {
            action: 'upload_file',
            filename: 'corrompido_' + ts + '.txt',
            content: 'Isto nao e um JSON valido.',
            contentType: 'text/plain'
        };
    }

    // valid: generate 3 realistic orders
    return {
        action: 'upload_file',
        filename: 'lote_pedidos_' + ts + '.json',
        content: {
            lista_pedidos: [
                { id_pedido_arquivo: 'BAT-' + ts + '-1', id_cliente_arquivo: 'CLI-MARIA', itens_pedido_arquivo: [{ sku: 'CURSO-AWS-SAA', qtd: 2 }] },
                { id_pedido_arquivo: 'BAT-' + ts + '-2', id_cliente_arquivo: 'CLI-CARLOS', itens_pedido_arquivo: [{ sku: 'CURSO-AZ-104', qtd: 1 }] },
                { id_pedido_arquivo: 'BAT-' + ts + '-3', id_cliente_arquivo: 'CLI-ANA', itens_pedido_arquivo: [{ sku: 'CURSO-K8S', qtd: 3 }] }
            ]
        },
        contentType: 'application/json'
    };
}

async function testS3(scenario) {
    scenario = scenario || 'valid';
    const payload = buildBatchPayload(scenario);

    const labelMap = {
        'valid': 'Upload Lote Valido',
        'invalid-schema': 'Schema Invalido',
        'corrupt': 'Arquivo Corrompido',
        'list': 'Listar Arquivos'
    };
    const label = 'Upload: ' + labelMap[scenario];

    if (scenario === 'list') {
        log('warn', label, 'Buscando lista de arquivos...');
    } else {
        log('warn', label, 'Enviando ' + payload.filename + '...');
    }

    const res = await apiPost(TEST_ENDPOINT, payload);

    if (res.status === 200) {
        if (scenario === 'valid') {
            const qtd = (payload.content.lista_pedidos || []).length;
            showInlineResult('batch', 'pass', label, res.data, {
                'Arquivo': payload.filename,
                'Pedidos': qtd + ' pedido(s)',
                'Status HTTP': res.status
            });
        } else if (scenario === 'list') {
            const files = res.data.files || res.data.arquivos || [];
            showInlineResult('batch', 'pass', label, res.data, {
                'Arquivos encontrados': files.length
            });
        } else {
            showInlineResult('batch', 'pass', label + ' (arquivo enviado, aguardando processamento)', res.data);
        }
        logResponse('pass', label, res);
    } else {
        showInlineResult('batch', 'fail', label, res.data);
        logResponse('fail', label, res);
    }
}
