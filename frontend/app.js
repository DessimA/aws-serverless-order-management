let currentUser  = null;
let currentToken = null;
let catalogCache = [];
let currentOrderId = null;
let activeProviderFilter = 'all';
let activeTipoFilter     = 'all';
let pendingOrderId = null;

document.addEventListener('DOMContentLoaded', init);

function init() {
    const token = localStorage.getItem('oms_token');
    const user  = localStorage.getItem('oms_user');

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

    document.querySelectorAll('.filter-chip[data-filter="provider"]').forEach(btn => {
        btn.addEventListener('click', () => setProviderFilter(btn.dataset.value));
    });

    document.querySelectorAll('.filter-chip[data-filter="tipo"]').forEach(btn => {
        btn.addEventListener('click', () => setTipoFilter(btn.dataset.value));
    });

    const ordersList = document.getElementById('orders-list');
    if (ordersList) {
        ordersList.addEventListener('click', function handleOrderClick(e) {
            const card = e.target.closest('.order-card');
            if (card && card.dataset.orderId) {
                viewOrderDetail(card.dataset.orderId);
            }
        });
    }
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
            throw new Error('token-invalid');
        }
    } catch (e) {
        logout();
    }
}

function showAuth() {
    document.getElementById('view-app').style.display  = 'none';
    document.getElementById('view-auth').style.display = '';
    document.getElementById('auth-error').classList.add('d-none');
}

function showApp() {
    document.getElementById('view-auth').style.display = 'none';
    document.getElementById('view-app').style.display  = '';
    const emailEl = document.getElementById('user-email-display');
    if (emailEl && currentUser) emailEl.textContent = currentUser.email;
}

async function handleRegister() {
    const email    = document.getElementById('register-email').value.trim();
    const password = document.getElementById('register-password').value;
    const confirm  = document.getElementById('register-confirm').value;
    const errorEl  = document.getElementById('auth-error');
    const btn = document.querySelector('#register-form .cc-btn-primary');
    if (!btn) return;
    const originalHtml = btn.innerHTML;

    errorEl.classList.add('d-none');

    if (password.length < 8) {
        return showAuthError('Senha deve ter no mínimo 8 caracteres.');
    }
    if (password !== confirm) {
        return showAuthError('Senhas não conferem.');
    }

    btn.disabled = true;
    btn.innerHTML = '<span class="spinner-border spinner-border-sm me-1"></span>Criando...';
    try {
        const res = await fetch(`${CUSTOMERS_ENDPOINT}/register`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ email, password })
        });
        if (res.status === 201) {
            document.getElementById('login-email').value    = email;
            document.getElementById('login-password').value = password;
            document.getElementById('login-tab').click();
            handleLogin();
        } else if (res.status === 409) {
            showAuthError('Email já cadastrado.');
        } else {
            const data = await res.json().catch(() => ({}));
            showAuthError(data.error || 'Erro ao criar conta.');
        }
    } catch (e) {
        showAuthError('Erro de conexão. Tente novamente.');
    } finally {
        btn.disabled = false;
        btn.innerHTML = originalHtml;
    }
}

async function handleLogin() {
    const email    = document.getElementById('login-email').value.trim();
    const password = document.getElementById('login-password').value;
    const btn = document.querySelector('#login-form .cc-btn-primary');
    if (!btn) return;
    const originalHtml = btn.innerHTML;

    document.getElementById('auth-error').classList.add('d-none');

    btn.disabled = true;
    btn.innerHTML = '<span class="spinner-border spinner-border-sm me-1"></span>Entrando...';
    try {
        const res = await fetch(`${CUSTOMERS_ENDPOINT}/login`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ email, password })
        });
        if (res.ok) {
            const data = await res.json();
            currentToken = data.token;
            currentUser  = { clienteId: data.clienteId, email };
            localStorage.setItem('oms_token', currentToken);
            localStorage.setItem('oms_user', JSON.stringify(currentUser));
            showApp();
            showView('catalog');
            loadCatalog();
        } else if (res.status === 401) {
            showAuthError('Email ou senha inválidos.');
        } else {
            showAuthError('Erro ao fazer login.');
        }
    } catch (e) {
        showAuthError('Erro de conexão. Tente novamente.');
    } finally {
        btn.disabled = false;
        btn.innerHTML = originalHtml;
    }
}

function showAuthError(message) {
    const el = document.getElementById('auth-error');
    el.textContent = message;
    el.classList.remove('d-none');
}

function logout() {
    localStorage.removeItem('oms_token');
    localStorage.removeItem('oms_user');
    currentToken    = null;
    currentUser     = null;
    catalogCache    = [];
    currentOrderId  = null;
    showAuth();
}

function showView(viewName) {
    document.querySelectorAll('#view-catalog, #view-orders, #view-order-detail').forEach(el => {
        el.style.display = 'none';
    });

    const target = document.getElementById(`view-${viewName}`);
    if (target) target.style.display = '';

    document.querySelectorAll('.cc-nav-btn').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.view === viewName);
    });

    if (viewName === 'orders') loadOrders();
}

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

    const grid  = document.getElementById('catalog-grid');
    const empty = document.getElementById('catalog-empty');

    if (filtered.length === 0) {
        grid.innerHTML = '';
        empty.classList.remove('d-none');
        return;
    }

    empty.classList.add('d-none');

    grid.innerHTML = filtered.map((item, index) => {
        const providerClass = (item.provider || '').toLowerCase();
        const tipoClass     = (item.tipo || '').toLowerCase();
        const duracao       = item.duracao ? `<span class="course-duration"><span class="material-icons">schedule</span>${escapeHtml(item.duracao)}</span>` : '';

        return `
            <div class="col-12 col-sm-6 col-lg-4"
                 style="animation-delay: ${index * 55}ms">
                <div class="card course-card course-card-enter h-100">
                    <div class="card-body d-flex flex-column">
                        <div class="course-badges">
                            <span class="badge-provider ${providerClass}">${escapeHtml(item.provider)}</span>
                            <span class="badge-tipo ${tipoClass}">${escapeHtml(item.tipo)}</span>
                        </div>
                        <h3 class="course-name">${escapeHtml(item.nome)}</h3>
                        <p class="course-desc">${escapeHtml(item.descricao || '')}</p>
                        <div class="mt-auto">
                            <div class="course-meta">
                                <span class="badge-nivel">${escapeHtml(item.nivel || '')}</span>
                                ${duracao}
                            </div>
                            <div class="course-footer">
                                <span class="course-price">${formatPrice(item.preco)}</span>
                                <button class="btn-comprar" onclick="buyCourse('${item.cursoId}','${escapeHtml(item.nome)}',${item.preco},this)">
                                    <span class="material-icons">shopping_cart</span>
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
    document.querySelectorAll('.filter-chip[data-filter="provider"]').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.value === value);
    });
    renderCatalog();
}

function setTipoFilter(value) {
    activeTipoFilter = value;
    document.querySelectorAll('.filter-chip[data-filter="tipo"]').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.value === value);
    });
    renderCatalog();
}

async function buyCourse(cursoId, nome, preco, btn) {
    const pedidoId = `ORD-${Date.now()}`;
    const payload  = {
        pedidoId,
        clienteId: currentUser.clienteId,
        itens: [{ sku: cursoId, qtd: 1, preco }]
    };
    const originalHtml = btn.innerHTML;
    btn.disabled = true;
    btn.innerHTML = '<span class="spinner-border spinner-border-sm"></span>';

    try {
        const res = await fetch(ORDERS_ENDPOINT, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });
        if (res.ok) {
            pendingOrderId = pedidoId;
            showToast('Pedido realizado com sucesso!', 'success');
            showView('orders');
        } else {
            const data = await res.json().catch(() => ({}));
            showToast(data.error || 'Erro ao realizar pedido.', 'danger');
        }
    } catch (e) {
        showToast('Erro de conexao. Tente novamente.', 'danger');
    } finally {
        btn.disabled = false;
        btn.innerHTML = originalHtml;
    }
}

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
            renderOrders([], true);
        }
    } catch (e) {
        renderOrders([], true);
    }

    document.getElementById('orders-loading').classList.add('d-none');
}

function renderOrders(orders, hasError) {
    const list  = document.getElementById('orders-list');
    const empty = document.getElementById('orders-empty');

    if (hasError) {
        list.innerHTML = '';
        empty.classList.add('d-none');
        list.innerHTML = `
            <div class="cc-empty-state">
                <span class="material-icons cc-empty-icon">cloud_off</span>
                <p class="text-secondary mt-2 mb-0">Nao foi possivel carregar os pedidos.</p>
                <button class="btn btn-outline-primary btn-sm mt-3" onclick="loadOrders()">
                    <span class="material-icons fs-6 align-text-bottom me-1">refresh</span>
                    Tentar novamente
                </button>
            </div>`;
        return;
    }

    if (pendingOrderId) {
        const banner = document.createElement('div');
        banner.className = 'alert alert-info small py-2 mb-3';
        banner.textContent = 'Seu pedido esta sendo processado e aparecera em breve na lista.';
        list.prepend(banner);
        setTimeout(() => {
            pendingOrderId = null;
            banner.remove();
        }, 8000);
    }

    if (!orders || orders.length === 0) {
        list.innerHTML = '';
        empty.classList.remove('d-none');
        return;
    }

    empty.classList.add('d-none');

    const sorted = [...orders].sort((a, b) => {
        const da = a.updatedAt || a.processedAt || a.eventTime || '';
        const db = b.updatedAt || b.processedAt || b.eventTime || '';
        return db.localeCompare(da);
    });

    list.innerHTML = sorted.map((order, index) => {
        const items    = order.items || order.itens || [];
        const total    = calculateOrderTotal(items);
        const date     = formatDatetime(order.updatedAt || order.processedAt || order.eventTime);
        const statusCl = escapeHtml(order.status || 'PROCESSED');

        const itemsHtml = items.length > 0
            ? items.map(item => `
                <div class="order-line-item">
                    <span class="order-line-sku">${escapeHtml(item.sku)}</span>
                    <span class="order-line-qty">x${item.qtd || 1}</span>
                    <span class="order-line-price">${formatPrice((item.preco || 0) * (item.qtd || 1))}</span>
                </div>
            `).join('')
            : '<p class="text-secondary small mb-0" style="font-size:0.78rem;">Sem itens registrados</p>';

        const totalHtml = items.length > 0 ? `
            <div class="order-card-total">
                <span class="order-total-label">Total</span>
                <span class="order-total-value">${formatPrice(total)}</span>
            </div>
        ` : '';

        return `
            <div class="order-card order-card-enter status-${statusCl}"
                 style="animation-delay: ${index * 45}ms"
                 data-order-id="${escapeHtml(order.orderId)}">
                <div class="order-card-inner">
                    <div class="order-card-top">
                        <div class="order-id-row">
                            <code class="order-id">${escapeHtml(order.orderId)}</code>
                            <span class="status-pill ${statusCl}">${statusCl}</span>
                        </div>
                        <time class="order-date">${date}</time>
                    </div>
                    <div class="order-items-list">
                        ${itemsHtml}
                    </div>
                    ${totalHtml}
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
            showToast('Pedido nao encontrado ou acesso negado.', 'danger');
        }
    } catch (e) {
        showToast('Erro ao carregar detalhe do pedido.', 'danger');
    }
}

function renderOrderDetail(order) {
    document.getElementById('update-form').classList.add('d-none');
    document.getElementById('detail-feedback').innerHTML = '';

    const items    = order.items || order.itens || [];
    const total    = calculateOrderTotal(items);
    const statusCl = escapeHtml(order.status || 'PROCESSED');
    const date     = formatDatetime(order.updatedAt || order.processedAt || order.eventTime);

    const rowsHtml = items.length > 0
        ? items.map(item => `
            <div class="detail-item-row">
                <span class="detail-item-sku">${escapeHtml(item.sku)}</span>
                <span class="detail-item-qty">x${item.qtd || 1}</span>
                <span class="detail-item-price">${formatPrice((item.preco || 0) * (item.qtd || 1))}</span>
            </div>
        `).join('')
        : '<p class="text-secondary small p-0 mb-0">Sem itens registrados</p>';

    document.getElementById('detail-card').innerHTML = `
        <div class="detail-card">
            <div class="detail-header">
                <div class="detail-header-left">
                    <code class="detail-order-id">${escapeHtml(order.orderId)}</code>
                    <span class="status-pill ${statusCl}">${statusCl}</span>
                </div>
                <time class="detail-meta">${date}</time>
            </div>
            <div class="detail-items-section">
                <p class="detail-items-label">Itens</p>
                ${rowsHtml}
            </div>
            ${items.length > 0 ? `
            <div class="detail-total-row">
                <span class="detail-total-label">Total</span>
                <span class="detail-total-value">${formatPrice(total)}</span>
            </div>` : ''}
        </div>
    `;

    const actions = document.getElementById('detail-actions');
    actions.style.display = order.status === 'CANCELLED' ? 'none' : 'flex';

    const select    = document.getElementById('update-curso');
    const available = catalogCache.filter(c => c.disponivel !== false);
    select.innerHTML = available.map(c =>
        `<option value="${c.cursoId}" data-preco="${c.preco}">${escapeHtml(c.nome)}</option>`
    ).join('');
}

async function cancelOrder() {
    if (!confirm('Tem certeza que deseja cancelar este pedido?')) return;

    try {
        const res = await fetch(`${ORDERS_ENDPOINT}/${currentOrderId}/cancel`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${currentToken}` },
            body: '{}'
        });

        if (res.status === 202) {
            document.getElementById('detail-feedback').innerHTML =
                '<div class="alert alert-info small py-2">Cancelamento solicitado. O status será atualizado em breve.</div>';
            setTimeout(() => viewOrderDetail(currentOrderId), 3000);
        } else if (res.status === 409) {
            const data = await res.json().catch(() => ({}));
            document.getElementById('detail-feedback').innerHTML =
                `<div class="alert alert-warning small py-2">${data.error || 'Pedido já cancelado.'}</div>`;
        } else {
            document.getElementById('detail-feedback').innerHTML =
                '<div class="alert alert-danger small py-2">Erro ao cancelar pedido.</div>';
        }
    } catch (e) {
        document.getElementById('detail-feedback').innerHTML =
            '<div class="alert alert-danger small py-2">Erro de conexão.</div>';
    }
}

function showUpdateForm() {
    const form = document.getElementById('update-form');
    form.classList.toggle('d-none');
    document.getElementById('detail-feedback').innerHTML = '';
}

async function submitUpdate() {
    const select         = document.getElementById('update-curso');
    const cursoId        = select.value;
    const qtd            = parseInt(document.getElementById('update-qtd').value, 10) || 1;
    const selectedOption = select.options[select.selectedIndex];
    const preco          = parseFloat(selectedOption.dataset.preco) || 0;
    const novosItens     = [{ sku: cursoId, qtd, preco }];

    try {
        const res = await fetch(`${ORDERS_ENDPOINT}/${currentOrderId}`, {
            method: 'PATCH',
            headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${currentToken}` },
            body: JSON.stringify({ novosItens })
        });

        if (res.status === 202) {
            document.getElementById('detail-feedback').innerHTML =
                '<div class="alert alert-info small py-2">Atualização solicitada. O status será atualizado em breve.</div>';
            showUpdateForm();
        } else if (res.status === 409) {
            const data = await res.json().catch(() => ({}));
            document.getElementById('detail-feedback').innerHTML =
                `<div class="alert alert-warning small py-2">${data.error || 'Não é possível atualizar um pedido cancelado.'}</div>`;
        } else {
            document.getElementById('detail-feedback').innerHTML =
                '<div class="alert alert-danger small py-2">Erro ao atualizar pedido.</div>';
        }
    } catch (e) {
        document.getElementById('detail-feedback').innerHTML =
            '<div class="alert alert-danger small py-2">Erro de conexão.</div>';
    }
}

function calculateOrderTotal(items) {
    return (items || []).reduce((sum, item) => {
        return sum + (Number(item.preco || 0) * Number(item.qtd || 1));
    }, 0);
}

function escapeHtml(text) {
    if (text == null) return '';
    return String(text)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

function showToast(message, type) {
    const toast = document.getElementById('app-toast');
    const inner = document.getElementById('app-toast-inner');
    if (!toast || !inner) return;
    inner.className = 'alert alert-' + type + ' mb-0 py-2 small text-center';
    inner.textContent = message;
    toast.classList.remove('d-none');
    setTimeout(() => toast.classList.add('d-none'), 3500);
}

function formatPrice(value) {
    if (value == null) return '';
    return Number(value).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
}

function openTermsModal() {
    const modalEl = document.getElementById('modal-terms');
    if (!modalEl) return;
    const modal = new bootstrap.Modal(modalEl);
    modal.show();
}

function formatDatetime(isoString) {
    if (!isoString) return '';
    try {
        return new Date(isoString).toLocaleString('pt-BR', {
            day: '2-digit', month: 'short', year: 'numeric',
            hour: '2-digit', minute: '2-digit'
        });
    } catch (e) {
        return isoString;
    }
}
