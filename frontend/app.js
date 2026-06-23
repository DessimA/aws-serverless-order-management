// === ESTADO ===
let currentUser = null;
let currentToken = null;
let catalogCache = [];
let currentOrderId = null;
let activeProviderFilter = 'all';
let activeTipoFilter = 'all';

// === INICIALIZACAO ===
document.addEventListener('DOMContentLoaded', init);

function init() {
    const token = localStorage.getItem('oms_token');
    const user = localStorage.getItem('oms_user');
    if (token && user) {
        currentToken = token;
        try {
            currentUser = JSON.parse(user);
        } catch (e) {
            showAuth();
            return;
        }
        validateToken();
    } else {
        showAuth();
    }

    document.querySelectorAll('.filter-pill[data-filter="provider"]').forEach(btn => {
        btn.addEventListener('click', () => setProviderFilter(btn.dataset.value));
    });
    document.querySelectorAll('.filter-pill[data-filter="tipo"]').forEach(btn => {
        btn.addEventListener('click', () => setTipoFilter(btn.dataset.value));
    });
}

async function validateToken() {
    try {
        const res = await fetch(`${CUSTOMERS_ENDPOINT}/me`, {
            headers: { 'Authorization': `Bearer ${currentToken}` }
        });
        if (res.ok) {
            const data = await res.json();
            currentUser = { clienteId: data.clienteId, email: data.email };
            localStorage.setItem('oms_user', JSON.stringify(currentUser));
            showApp();
            showView('catalog');
            loadCatalog();
        } else {
            throw new Error('Token invalid');
        }
    } catch (e) {
        logout();
    }
}

// === AUTENTICACAO ===
function showAuth() {
    document.getElementById('view-app').style.display = 'none';
    document.getElementById('view-auth').style.display = '';
    document.getElementById('auth-error').classList.add('d-none');
}

function showApp() {
    document.getElementById('view-auth').style.display = 'none';
    document.getElementById('view-app').style.display = '';
    document.getElementById('user-email-display').textContent = currentUser ? currentUser.email : '';
}

async function handleRegister() {
    const email = document.getElementById('register-email').value.trim();
    const password = document.getElementById('register-password').value;
    const confirm = document.getElementById('register-confirm').value;
    const errorEl = document.getElementById('auth-error');

    errorEl.classList.add('d-none');

    if (password.length < 8) {
        errorEl.textContent = 'Senha deve ter no minimo 8 caracteres.';
        errorEl.classList.remove('d-none');
        return;
    }
    if (password !== confirm) {
        errorEl.textContent = 'Senhas nao conferem.';
        errorEl.classList.remove('d-none');
        return;
    }

    try {
        const res = await fetch(`${CUSTOMERS_ENDPOINT}/register`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ email, password })
        });
        if (res.status === 201) {
            document.getElementById('login-email').value = email;
            document.getElementById('login-password').value = password;
            document.getElementById('login-tab').click();
            handleLogin();
        } else if (res.status === 409) {
            errorEl.textContent = 'Email ja cadastrado.';
            errorEl.classList.remove('d-none');
        } else {
            const data = await res.json().catch(() => ({}));
            errorEl.textContent = data.error || 'Erro ao criar conta.';
            errorEl.classList.remove('d-none');
        }
    } catch (e) {
        errorEl.textContent = 'Erro de conexao. Tente novamente.';
        errorEl.classList.remove('d-none');
    }
}

async function handleLogin() {
    const email = document.getElementById('login-email').value.trim();
    const password = document.getElementById('login-password').value;
    const errorEl = document.getElementById('auth-error');

    errorEl.classList.add('d-none');

    try {
        const res = await fetch(`${CUSTOMERS_ENDPOINT}/login`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ email, password })
        });
        if (res.ok) {
            const data = await res.json();
            currentToken = data.token;
            currentUser = { clienteId: data.clienteId, email: email };
            localStorage.setItem('oms_token', currentToken);
            localStorage.setItem('oms_user', JSON.stringify(currentUser));
            showApp();
            showView('catalog');
            loadCatalog();
        } else if (res.status === 401) {
            errorEl.textContent = 'Email ou senha invalidos.';
            errorEl.classList.remove('d-none');
        } else {
            errorEl.textContent = 'Erro ao fazer login.';
            errorEl.classList.remove('d-none');
        }
    } catch (e) {
        errorEl.textContent = 'Erro de conexao. Tente novamente.';
        errorEl.classList.remove('d-none');
    }
}

function logout() {
    localStorage.removeItem('oms_token');
    localStorage.removeItem('oms_user');
    currentToken = null;
    currentUser = null;
    catalogCache = [];
    currentOrderId = null;
    showAuth();
}

// === NAVEGACAO ===
function showView(viewName) {
    document.querySelectorAll('#view-catalog, #view-orders, #view-order-detail').forEach(el => {
        el.style.display = 'none';
    });
    const target = document.getElementById(`view-${viewName}`);
    if (target) {
        target.style.display = '';
    }
    document.querySelectorAll('.nav-btn').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.view === viewName);
    });
    if (viewName === 'orders') {
        loadOrders();
    }
}

// === CATALOGO ===
async function loadCatalog() {
    document.getElementById('catalog-loading').classList.remove('d-none');
    document.getElementById('catalog-grid').innerHTML = '';
    document.getElementById('catalog-empty').classList.add('d-none');

    try {
        const res = await fetch(CATALOG_ENDPOINT);
        if (res.ok) {
            const data = await res.json();
            catalogCache = data.items || [];
        } else {
            catalogCache = [];
        }
    } catch (e) {
        catalogCache = [];
    }

    document.getElementById('catalog-loading').classList.add('d-none');
    renderCatalog();
}

function renderCatalog() {
    let filtered = catalogCache.filter(item => item.disponivel !== false);

    if (activeProviderFilter !== 'all') {
        filtered = filtered.filter(item => item.provider === activeProviderFilter);
    }
    if (activeTipoFilter !== 'all') {
        filtered = filtered.filter(item => item.tipo === activeTipoFilter);
    }

    const grid = document.getElementById('catalog-grid');
    const empty = document.getElementById('catalog-empty');

    if (filtered.length === 0) {
        grid.innerHTML = '';
        empty.classList.remove('d-none');
        return;
    }

    empty.classList.add('d-none');
    grid.innerHTML = filtered.map(item => {
        const providerBadge = providerBadgeHtml(item.provider);
        const tipoBadge = tipoBadgeHtml(item.tipo);
        const nivelBadge = nivelBadgeHtml(item.nivel);
        return `
            <div class="col-12 col-sm-6 col-lg-4 col-xl-3">
                <div class="card border-secondary h-100 course-card">
                    <div class="card-body d-flex flex-column">
                        <div class="mb-2">
                            ${providerBadge} ${tipoBadge}
                        </div>
                        <h6 class="card-title mb-1">${escapeHtml(item.nome)}</h6>
                        <p class="card-text small text-secondary course-desc">${escapeHtml(item.descricao || '')}</p>
                        <div class="mt-auto">
                            <div class="d-flex justify-content-between align-items-center mb-2">
                                <span class="small text-secondary">${nivelBadge}</span>
                                <span class="small text-secondary">${escapeHtml(item.cargaHoraria || '')}</span>
                            </div>
                            <div class="d-flex justify-content-between align-items-center">
                                <span class="fw-bold">${formatPrice(item.preco)}</span>
                                <button class="btn btn-primary btn-sm" onclick="buyCourse('${item.cursoId}','${escapeHtml(item.nome)}',${item.preco})">
                                    Comprar
                                </button>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        `;
    }).join('');
}

function setProviderFilter(value) {
    activeProviderFilter = value;
    document.querySelectorAll('.filter-pill[data-filter="provider"]').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.value === value);
    });
    renderCatalog();
}

function setTipoFilter(value) {
    activeTipoFilter = value;
    document.querySelectorAll('.filter-pill[data-filter="tipo"]').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.value === value);
    });
    renderCatalog();
}

async function buyCourse(cursoId, nome, preco) {
    const pedidoId = `ORD-${Date.now()}`;
    const payload = {
        pedidoId: pedidoId,
        clienteId: currentUser.clienteId,
        itens: [{ sku: cursoId, qtd: 1, preco: preco }]
    };

    try {
        const res = await fetch(API_ENDPOINT, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });
        if (res.ok) {
            alert('Pedido realizado com sucesso!');
            showView('orders');
        } else {
            const data = await res.json().catch(() => ({}));
            alert(data.error || 'Erro ao realizar pedido.');
        }
    } catch (e) {
        alert('Erro de conexao. Tente novamente.');
    }
}

// === MEUS PEDIDOS ===
async function loadOrders() {
    document.getElementById('orders-loading').classList.remove('d-none');
    document.getElementById('orders-list').innerHTML = '';
    document.getElementById('orders-empty').classList.add('d-none');

    try {
        const res = await fetch(ORDERS_ENDPOINT, {
            headers: { 'Authorization': `Bearer ${currentToken}` }
        });
        if (res.status === 401) {
            logout();
            return;
        }
        if (res.ok) {
            const data = await res.json();
            renderOrders(data.orders || []);
        } else {
            renderOrders([]);
        }
    } catch (e) {
        renderOrders([]);
    }

    document.getElementById('orders-loading').classList.add('d-none');
}

function renderOrders(orders) {
    const list = document.getElementById('orders-list');
    const empty = document.getElementById('orders-empty');

    if (orders.length === 0) {
        list.innerHTML = '';
        empty.classList.remove('d-none');
        return;
    }

    empty.classList.add('d-none');

    orders.sort((a, b) => {
        const da = a.processedAt || a.createdAt || '';
        const db = b.processedAt || b.createdAt || '';
        return db.localeCompare(da);
    });

    list.innerHTML = orders.map(order => {
        const firstItem = (order.itens && order.itens.length > 0)
            ? `${order.itens[0].sku} (x${order.itens[0].qtd})`
            : '';
        return `
            <div class="card border-secondary mb-2 order-item status-${order.status}">
                <div class="card-body py-2 px-3 d-flex flex-wrap align-items-center justify-content-between">
                    <div>
                        <span class="font-monospace small me-2">${escapeHtml(order.orderId)}</span>
                        ${statusBadge(order.status)}
                        <span class="text-secondary small ms-2">${formatDate(order.processedAt || order.createdAt)}</span>
                        ${firstItem ? `<div class="text-secondary small mt-1">${escapeHtml(firstItem)}</div>` : ''}
                    </div>
                    <button class="btn btn-outline-primary btn-sm" onclick="viewOrderDetail('${order.orderId}')">Ver Detalhes</button>
                </div>
            </div>
        `;
    }).join('');
}

async function viewOrderDetail(orderId) {
    try {
        const res = await fetch(`${ORDERS_ENDPOINT}/${orderId}`, {
            headers: { 'Authorization': `Bearer ${currentToken}` }
        });
        if (res.status === 401) {
            logout();
            return;
        }
        if (res.ok) {
            const order = await res.json();
            currentOrderId = orderId;
            renderOrderDetail(order);
            showView('order-detail');
        } else {
            alert('Pedido nao encontrado.');
        }
    } catch (e) {
        alert('Erro ao carregar detalhe do pedido.');
    }
}

// === DETALHE E ACOES ===
function renderOrderDetail(order) {
    const card = document.getElementById('detail-card');
    const actions = document.getElementById('detail-actions');
    const feedback = document.getElementById('detail-feedback');
    feedback.innerHTML = '';

    const itemsHtml = (order.itens || []).map(item => `
        <tr>
            <td class="small">${escapeHtml(item.sku)}</td>
            <td class="small">${item.qtd}</td>
            <td class="small">${formatPrice(item.preco)}</td>
        </tr>
    `).join('');

    card.innerHTML = `
        <div class="card border-secondary">
            <div class="card-body">
                <div class="d-flex flex-wrap align-items-center gap-2 mb-2">
                    <h6 class="mb-0 font-monospace">${escapeHtml(order.orderId)}</h6>
                    ${statusBadge(order.status)}
                </div>
                <div class="text-secondary small mb-2">${formatDate(order.processedAt || order.createdAt)}</div>
                <table class="table table-dark table-sm table-borderless mb-0">
                    <thead>
                        <tr><th class="small">Item</th><th class="small">Qtd</th><th class="small">Preco</th></tr>
                    </thead>
                    <tbody>${itemsHtml || '<tr><td colspan="3" class="small text-secondary">Nenhum item</td></tr>'}</tbody>
                </table>
            </div>
        </div>
    `;

    if (order.status === 'CANCELLED') {
        actions.style.display = 'none';
    } else {
        actions.style.display = 'flex';
    }

    const select = document.getElementById('update-curso');
    const available = catalogCache.filter(c => c.disponivel !== false);
    select.innerHTML = available.map(c => `<option value="${c.cursoId}" data-preco="${c.preco}">${escapeHtml(c.nome)}</option>`).join('');
}

async function cancelOrder() {
    if (!confirm('Tem certeza que deseja cancelar este pedido?')) return;

    try {
        const res = await fetch(`${ORDERS_ENDPOINT}/${currentOrderId}/cancel`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Authorization': `Bearer ${currentToken}`
            },
            body: '{}'
        });
        if (res.status === 202) {
            document.getElementById('detail-feedback').innerHTML =
                '<div class="alert alert-info small py-2">Cancelamento solicitado. O status sera atualizado em breve.</div>';
            setTimeout(() => viewOrderDetail(currentOrderId), 3000);
        } else if (res.status === 409) {
            const data = await res.json().catch(() => ({}));
            document.getElementById('detail-feedback').innerHTML =
                `<div class="alert alert-warning small py-2">${data.error || 'Pedido ja cancelado.'}</div>`;
        } else {
            document.getElementById('detail-feedback').innerHTML =
                '<div class="alert alert-danger small py-2">Erro ao cancelar pedido.</div>';
        }
    } catch (e) {
        document.getElementById('detail-feedback').innerHTML =
            '<div class="alert alert-danger small py-2">Erro de conexao.</div>';
    }
}

function showUpdateForm() {
    const form = document.getElementById('update-form');
    form.classList.toggle('d-none');
    document.getElementById('detail-feedback').innerHTML = '';
}

async function submitUpdate() {
    const cursoId = document.getElementById('update-curso').value;
    const qtd = parseInt(document.getElementById('update-qtd').value, 10) || 1;
    const select = document.getElementById('update-curso');
    const selectedOption = select.options[select.selectedIndex];
    const preco = parseFloat(selectedOption.dataset.preco) || 0;

    const novosItens = [{ sku: cursoId, qtd, preco }];

    try {
        const res = await fetch(`${ORDERS_ENDPOINT}/${currentOrderId}`, {
            method: 'PATCH',
            headers: {
                'Content-Type': 'application/json',
                'Authorization': `Bearer ${currentToken}`
            },
            body: JSON.stringify({ novosItens })
        });
        if (res.status === 202) {
            document.getElementById('detail-feedback').innerHTML =
                '<div class="alert alert-info small py-2">Atualizacao solicitada. O status sera atualizado em breve.</div>';
            showUpdateForm();
        } else if (res.status === 409) {
            const data = await res.json().catch(() => ({}));
            document.getElementById('detail-feedback').innerHTML =
                `<div class="alert alert-warning small py-2">${data.error || 'Nao e possivel atualizar um pedido cancelado.'}</div>`;
        } else {
            document.getElementById('detail-feedback').innerHTML =
                '<div class="alert alert-danger small py-2">Erro ao atualizar pedido.</div>';
        }
    } catch (e) {
        document.getElementById('detail-feedback').innerHTML =
            '<div class="alert alert-danger small py-2">Erro de conexao.</div>';
    }
}

// === UTILITARIOS ===
function escapeHtml(text) {
    if (!text) return '';
    return String(text).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function formatDate(isoString) {
    if (!isoString) return '';
    try {
        const d = new Date(isoString);
        return d.toLocaleDateString('pt-BR');
    } catch (e) {
        return isoString;
    }
}

function formatPrice(value) {
    if (value == null) return '';
    return Number(value).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
}

function statusBadge(status) {
    const map = {
        'PROCESSED': 'bg-primary',
        'UPDATED': 'bg-warning text-dark',
        'CANCELLED': 'bg-secondary'
    };
    const cls = map[status] || 'bg-secondary';
    return `<span class="badge ${cls}">${escapeHtml(status)}</span>`;
}

function providerBadgeHtml(provider) {
    const map = { 'AWS': 'bg-warning text-dark', 'Azure': 'bg-primary', 'GCP': 'bg-danger' };
    const cls = map[provider] || 'bg-secondary';
    return provider ? `<span class="badge ${cls}">${escapeHtml(provider)}</span>` : '';
}

function tipoBadgeHtml(tipo) {
    const map = { 'curso': 'bg-purple', 'voucher': 'bg-success' };
    const cls = map[tipo] || 'bg-secondary';
    return tipo ? `<span class="badge ${cls}">${escapeHtml(tipo)}</span>` : '';
}

function nivelBadgeHtml(nivel) {
    const map = { 'Iniciante': 'bg-secondary', 'Intermediario': 'bg-warning text-dark', 'Avancado': 'bg-danger' };
    const cls = map[nivel] || 'bg-secondary';
    return nivel ? `<span class="badge ${cls}">${escapeHtml(nivel)}</span>` : '';
}
