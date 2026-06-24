let lastOrderId = '';

const RESULT_TYPE = {
    pass: { border: 'border-success', bg: 'bg-success', icon: 'check_circle', statusText: 'Sucesso', cssVar: 'success' },
    fail: { border: 'border-danger', bg: 'bg-danger', icon: 'error', statusText: 'Erro', cssVar: 'danger' },
    warn: { border: 'border-warning', bg: 'bg-warning', icon: 'warning', statusText: 'Aviso', cssVar: 'warning' },
};

const PLACEHOLDERS = {
    create: 'Preencha os campos e clique em <strong>Criar Pedido</strong>.',
    consult: 'Digite um Order ID e clique em <strong>Consultar</strong>.',
    manage: 'Digite um Order ID e clique em <strong>Cancelar</strong> ou <strong>Atualizar</strong>.',
    batch: 'Clique em <strong>Gerar e Enviar Lote de Teste</strong>.',
};

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

    document.body.addEventListener('click', e => {
        const btn = e.target.closest('button[data-action]');
        if (!btn) return;
        const action = btn.dataset.action;
        const scenario = btn.dataset.scenario || '';
        if (typeof window[action] === 'function') {
            window[action](scenario);
        }
    });

    Object.keys(PLACEHOLDERS).forEach(tab => resetInlineResult(tab, PLACEHOLDERS[tab]));
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

function now() {
    return new Date().toLocaleTimeString('pt-BR', { hour12: false });
}

function escapeHtml(text) {
    if (!text) return '';
    return String(text).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function generateId(prefix) {
    return prefix + Date.now();
}

function readCreateForm() {
    const clienteNome = document.getElementById('createCliente').value.trim() || 'Cliente Teste';
    const produtoNome = document.getElementById('createProduto').value.trim() || 'Produto Teste';
    const qtd = parseInt(document.getElementById('createQtd').value, 10) || 1;
    const preco = parseFloat(document.getElementById('createPreco').value) || 99.90;
    return {
        pedidoId: generateId('ORD-'),
        clienteId: 'CLI-' + clienteNome.replace(/\s+/g, '') + '-' + Math.floor(Math.random() * 1000),
        clienteNome, produtoNome, qtd, preco,
    };
}

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

function showInlineResult(tab, type, label, data, detail) {
    const card = document.getElementById('result-' + tab);
    if (!card) return;

    const cfg = RESULT_TYPE[type] || RESULT_TYPE.warn;
    const borderColor = `rgba(var(--bs-${cfg.cssVar}-rgb), 0.05)`;

    card.className = 'card ' + cfg.border;
    card.style.background = borderColor;

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
                <span class="material-icons ${cfg.bg} bg-opacity-10 p-1 rounded" style="font-size:1.1rem;">${cfg.icon}</span>
                <span class="fw-semibold small">${escapeHtml(cfg.statusText)}</span>
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
    if (card) {
        card.innerHTML = `<div class="card-body text-center text-secondary small">
            <span class="material-icons fs-3 mb-1 d-block">info</span>
            ${placeholder}
        </div>`;
    }
}

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
        container.innerHTML = '<p class="text-center text-secondary small py-4 mb-0 log-empty">Clique em qualquer ação para começar.</p>';
    }
    Object.entries(PLACEHOLDERS).forEach(([tab, text]) => resetInlineResult(tab, text));
}

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

async function apiFetch(url, options = {}) {
    try {
        const res = await fetch(url, options);
        const data = await res.json().catch(() => ({ raw: 'Could not parse response' }));
        return { status: res.status, data };
    } catch (err) {
        return { status: 0, data: { error: err.message || 'Network error' } };
    }
}

function buildOrderPayload(form, scenario) {
    if (scenario === 'auto') {
        const clientes = ['Maria Santos', 'Carlos Oliveira', 'Ana Costa', 'Pedro Lima', 'Juliana Souza', 'Lucas Pereira', 'Fernanda Alves', 'Rafael Martins', 'Beatriz Rocha', 'Gustavo Barbosa'];
        const produtos = [
            { nome: 'Curso AWS Solutions Architect', preco: 249.90 },
            { nome: 'Curso AWS Developer', preco: 199.90 },
            { nome: 'Curso AWS DevOps', preco: 299.90 },
            { nome: 'Curso AWS Security', preco: 349.90 },
            { nome: 'Curso AWS Advanced Networking', preco: 279.90 },
            { nome: 'Curso AWS Machine Learning', preco: 399.90 },
            { nome: 'Curso AWS Database', preco: 229.90 },
            { nome: 'Curso AWS Serverless', preco: 179.90 },
        ];
        const c = clientes[Math.floor(Math.random() * clientes.length)];
        const p = produtos[Math.floor(Math.random() * produtos.length)];
        const q = Math.floor(Math.random() * 5) + 1;
        return {
            pedidoId: generateId('ORD-'),
            clienteId: 'CLI-' + c.replace(/\s+/g, '') + '-' + Math.floor(Math.random() * 1000),
            itens: [{ sku: p.nome.replace(/\s+/g, '-'), qtd: q, preco: p.preco }],
        };
    }
    if (scenario === 'missing-pedido') {
        return { clienteId: generateId('CLI-'), itens: [{ sku: 'PROD-A', qtd: 1 }] };
    }
    if (scenario === 'missing-cliente') {
        return { pedidoId: generateId('ORD-'), itens: [{ sku: 'PROD-A', qtd: 1 }] };
    }
    if (scenario === 'invalid-json') {
        return '__INVALID_JSON__';
    }
    if (scenario === 'duplicate') {
        const id = lastOrderId || 'ORD-TEST-DUP';
        return { pedidoId: id, clienteId: 'CLI-DUP-001', itens: [{ sku: 'PROD-DUP', qtd: 1 }] };
    }
    const { pedidoId, produtoNome, qtd, preco } = form;
    return {
        pedidoId, clienteId: form.clienteId,
        itens: [{ sku: produtoNome.replace(/\s+/g, '-'), qtd, preco }],
    };
}

async function testAPI(scenario) {
    const form = readCreateForm();
    const payload = buildOrderPayload(form, scenario);
    const isError = ['missing-pedido', 'missing-cliente', 'invalid-json', 'duplicate'].includes(scenario);

    const label = isError ? `Novo Pedido: ${scenario}` : (scenario === 'auto' ? 'Novo Pedido: Automatico' : 'Novo Pedido');
    const tab = 'create';

    setLoading('btnCreateOrder', true);
    log('warn', label, `${isError ? 'Enviando pedido invalido...' : 'Enviando pedido...'}`);

    let res;
    if (scenario === 'invalid-json') {
        try {
            const r = await fetch(API_ENDPOINT, {
                method: 'POST', headers: { 'Content-Type': 'application/json' }, body: payload,
            });
            const d = await r.json().catch(() => ({ raw: 'Could not parse response' }));
            res = { status: r.status, data: d };
        } catch (err) {
            res = { status: 0, data: { error: err.message || 'Network error' } };
        }
    } else {
        res = await apiFetch(API_ENDPOINT, {
            method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload),
        });
    }

    setLoading('btnCreateOrder', false);

    if (!isError && res.status < 400 && payload.pedidoId) {
        lastOrderId = payload.pedidoId;
        updateLastOrderDisplay();
    }

    const detail = payload.pedidoId ? { 'Pedido ID': payload.pedidoId } : undefined;
    const type = res.status < 400 ? 'pass' : (isError ? 'warn' : 'fail');
    showInlineResult(tab, type, label, res.data, detail);
    logResponse(type, label, res);
}

async function testRead(scenario) {
    const orderId = scenario === 'nonexistent'
        ? generateId('ORD-NONEXISTENT-')
        : (scenario === 'last'
            ? (lastOrderId || 'ORD-TEST-001')
            : (document.getElementById('readOrderId').value.trim() || lastOrderId || 'ORD-TEST-001'));
    const label = 'Consultar: ' + orderId;

    log('warn', label, 'Buscando pedido...');
    const res = await apiFetch(READ_ENDPOINT.replace('{orderId}', encodeURIComponent(orderId)));

    const type = res.status === 200 ? 'pass' : res.status === 404 ? 'warn' : 'fail';
    const detail = res.status === 200 ? { 'Order ID': orderId } : undefined;

    showInlineResult('consult', type, label, res.data, detail);
    logResponse(type, label, res);

    const actions = document.getElementById('consult-actions');
    if (actions) {
        actions.classList.toggle('d-none', res.status !== 200);
    }
}

function buildManagePayload(scenario) {
    const orderId = scenario.includes('nonexistent')
        ? generateId('ORD-NONEXISTENT-')
        : (document.getElementById('lifecycleOrderId').value.trim() || generateId('ORD-NONEXISTENT-'));
    const produto = document.getElementById('mgmtProduto').value.trim() || 'Curso Azure';
    const qtd = parseInt(document.getElementById('mgmtQtd').value, 10) || 3;
    const preco = parseFloat(document.getElementById('mgmtPreco').value) || 199.90;
    return { pedidoId: orderId, novosItens: [{ sku: produto.replace(/\s+/g, '-'), qtd, preco }] };
}

async function testLifecycle(scenario) {
    const isNonexistent = scenario.includes('nonexistent');
    const action = scenario.replace('-nonexistent', '');
    const isUpdate = action === 'update';

    const mgmt = buildManagePayload(scenario);
    const detailType = isUpdate ? 'OrderUpdated' : 'OrderCancelled';
    const label = `Gerenciar: ${isUpdate ? 'Atualizar' : 'Cancelar'} ${isNonexistent ? '(inexistente)' : ''}`;

    log('warn', label, 'Publicando evento no EventBridge...');
    const res = await apiFetch(TEST_ENDPOINT, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-api-key': TEST_API_KEY },
        body: JSON.stringify({
            action: 'publish_event',
            detailType,
            detail: mgmt,
        }),
    });

    const type = res.status < 400 ? 'pass' : 'fail';
    showInlineResult('manage', type, label, res.data, { 'Order ID': mgmt.pedidoId });
    logResponse(type, label, res);
}

async function testCancelledUpdate() {
    const orderId = document.getElementById('lifecycleOrderId').value.trim() || generateId('ORD-NONEXISTENT-');
    const label = 'Gerenciar: Atualizar Pedido Cancelado (' + orderId + ')';
    const tab = 'manage';

    log('warn', label, '1/2: Cancelando pedido...');
    let res = await apiFetch(TEST_ENDPOINT, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-api-key': TEST_API_KEY },
        body: JSON.stringify({ action: 'publish_event', detailType: 'OrderCancelled', detail: { pedidoId: orderId } }),
    });
    logResponse(res.status < 400 ? 'pass' : 'fail', label + ' (cancel)', res);

    await new Promise(r => setTimeout(r, 2000));

    log('warn', label, '2/2: Tentando atualizar pedido cancelado...');
    const mgmt = { pedidoId: orderId, novosItens: [{ sku: 'SHOULD-NOT-APPEAR', qtd: 999, preco: 1.0 }] };
    res = await apiFetch(TEST_ENDPOINT, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-api-key': TEST_API_KEY },
        body: JSON.stringify({ action: 'publish_event', detailType: 'OrderUpdated', detail: mgmt }),
    });
    logResponse(res.status < 400 ? 'pass' : 'fail', label + ' (update)', res);

    const type = res.status < 400 ? 'warn' : 'fail';
    showInlineResult(tab, type, label, res.data, { 'Order ID': orderId });
}

async function testS3(scenario) {
    const label = 'Upload: ' + scenario;
    const tab = 'batch';
    log('warn', label, 'Processando...');

    let res;
    if (scenario === 'list') {
        res = await apiFetch(TEST_ENDPOINT, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'x-api-key': TEST_API_KEY },
            body: JSON.stringify({ action: 'list_files' }),
        });
    } else if (scenario === 'valid') {
        const clientes = ['João Silva', 'Maria Santos', 'Carlos Oliveira'];
        const produtos = [
            { nome: 'Curso AWS Practitioner', qtd: 1, preco: 149.90 },
            { nome: 'Curso AWS Solutions Architect', qtd: 2, preco: 249.90 },
        ];
        const pedidos = Array.from({ length: Math.floor(Math.random() * 3) + 2 }, (_, i) => ({
            pedidoId: `LOTE-${Date.now()}-${i + 1}`,
            clienteId: `CLI-LOTE-${i + 1}`,
            itens: [{ sku: produtos[i % produtos.length].nome.replace(/\s+/g, '-'), qtd: produtos[i % produtos.length].qtd, preco: produtos[i % produtos.length].preco }],
        }));
        const content = JSON.stringify({ lista_pedidos: pedidos, total: pedidos.length });
        res = await apiFetch(TEST_ENDPOINT, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'x-api-key': TEST_API_KEY },
            body: JSON.stringify({ action: 'upload_file', filename: 'lote_' + Date.now() + '.json', content }),
        });
    } else if (scenario === 'invalid-schema') {
        res = await apiFetch(TEST_ENDPOINT, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'x-api-key': TEST_API_KEY },
            body: JSON.stringify({ action: 'upload_file', filename: 'invalido_' + Date.now() + '.json', content: JSON.stringify({ sem_lista: true }) }),
        });
    } else if (scenario === 'corrupt') {
        res = await apiFetch(TEST_ENDPOINT, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'x-api-key': TEST_API_KEY },
            body: JSON.stringify({ action: 'upload_file', filename: 'corrupto_' + Date.now() + '.txt', content: 'isto nao e json', contentType: 'text/plain' }),
        });
    }

    if (!res) return;
    const type = res.status < 400 ? 'pass' : 'fail';
    showInlineResult(tab, type, label, res.data, { 'Arquivo': res.data?.key || res.data?.filename || '-' });
    logResponse(type, label, res);
}
