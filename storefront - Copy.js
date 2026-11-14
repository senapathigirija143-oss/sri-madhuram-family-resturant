const state = {
    menu: [],
    posters: [],
    settings: null,
    onlinePayment: null,
    selectedCategory: 'All Items',
    cart: []
};

const byId = id => document.getElementById(id);

function escapeHtml(value) {
    return String(value ?? '').replace(/[&<>"']/g, character => ({
        '&': '&amp;',
        '<': '&lt;',
        '>': '&gt;',
        '"': '&quot;',
        "'": '&#39;'
    })[character]);
}

function formatRupees(amount) {
    return `₹${Number(amount).toFixed(2)}`;
}

async function apiRequest(url, options = {}) {
    const response = await fetch(url, {
        method: options.method || 'GET',
        headers: options.body === undefined ? {} : { 'Content-Type': 'application/json' },
        body: options.body === undefined ? undefined : JSON.stringify(options.body)
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(result.error || `Request failed (${response.status}).`);
    return result;
}

function showMenuNotice(message, isError = false, retry = false) {
    const notice = byId('menu-notice');
    notice.replaceChildren();
    notice.classList.toggle('hidden', !message);
    notice.classList.toggle('border-red-200', isError);
    notice.classList.toggle('bg-red-50', isError);
    notice.classList.toggle('text-red-800', isError);
    notice.classList.toggle('border-amber-200', !isError);
    notice.classList.toggle('bg-amber-50', !isError);
    notice.classList.toggle('text-amber-900', !isError);
    if (!message) return;

    const text = document.createElement('span');
    text.textContent = message;
    notice.append(text);
    if (retry) {
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'ml-2 font-bold underline';
        button.textContent = 'Retry';
        button.addEventListener('click', loadPublicData);
        notice.append(button);
    }
}

function renderCategories() {
    const categories = ['All Items', ...new Set(state.menu.map(item => item.category))];
    byId('category-list').innerHTML = categories.map(category => `
        <button type="button" data-category="${escapeHtml(category)}"
            class="shrink-0 rounded-xl px-4 py-2 text-xs font-bold transition ${
                state.selectedCategory === category
                    ? 'bg-brand-red text-white'
                    : 'border bg-white text-gray-700 hover:bg-gray-100'
            }">${escapeHtml(category)}</button>
    `).join('');
}

function renderMenu() {
    const search = byId('menu-search').value.trim().toLocaleLowerCase();
    const items = state.menu.filter(item =>
        (state.selectedCategory === 'All Items' || item.category === state.selectedCategory) &&
        `${item.name} ${item.description} ${item.category}`.toLocaleLowerCase().includes(search)
    );

    byId('menu-grid').innerHTML = items.length ? items.map(item => `
        <article class="flex flex-col overflow-hidden rounded-2xl border bg-white shadow-sm">
            <img src="${escapeHtml(item.image)}" alt="${escapeHtml(item.name)}"
                class="h-44 w-full bg-gray-100 object-cover" loading="lazy">
            <div class="flex flex-1 flex-col p-4">
                <p class="text-[11px] font-bold uppercase tracking-wide text-brand-red">${escapeHtml(item.category)}</p>
                <h3 class="mt-1 font-black text-gray-900">${escapeHtml(item.name)}</h3>
                <p class="mt-2 flex-1 text-xs leading-relaxed text-gray-500">${escapeHtml(item.description)}</p>
                <div class="mt-4 flex items-center justify-between gap-3">
                    <strong class="text-lg">₹${Number(item.price).toFixed(2)}</strong>
                    <button type="button" data-add-item="${Number(item.id)}"
                        class="rounded-xl bg-stone-900 px-4 py-2 text-xs font-bold text-white hover:bg-black">
                        <i class="fa-solid fa-plus mr-1"></i>Add
                    </button>
                </div>
            </div>
        </article>
    `).join('') : `
        <p class="col-span-full rounded-xl border border-dashed bg-white p-8 text-center text-sm text-gray-500">
            ${state.menu.length ? 'No menu items match your search.' : 'No menu items are currently available.'}
        </p>
    `;
}

function renderPosters() {
    const section = byId('restaurant-posters');
    section.classList.toggle('hidden', state.posters.length === 0);
    byId('poster-list').innerHTML = state.posters.map(poster => `
        <article class="overflow-hidden rounded-2xl border bg-white shadow-sm">
            <img src="${escapeHtml(poster.image)}" alt="${escapeHtml(poster.title)}" class="h-48 w-full object-cover" loading="lazy">
            <div class="p-4">
                <h3 class="font-black">${escapeHtml(poster.title)}</h3>
                ${poster.description ? `<p class="mt-2 text-sm text-gray-600">${escapeHtml(poster.description)}</p>` : ''}
            </div>
        </article>
    `).join('');
}

async function loadPublicData() {
    showMenuNotice('Loading restaurant menu…');
    try {
        const data = await apiRequest('/api/public-data');
        if (!Array.isArray(data.menu) || !Array.isArray(data.posters) ||
            !data.settings || !Number.isFinite(Number(data.settings.delivery_fee)) ||
            !Number.isFinite(Number(data.settings.tax_rate))) {
            throw new Error('Restaurant data returned an invalid format.');
        }
        state.menu = data.menu.filter(item => Number.isSafeInteger(Number(item.id)) && Number(item.id) > 0);
        state.posters = data.posters;
        state.settings = data.settings;
        state.onlinePayment = data.payments;

        const upiOption = byId('upi-option');
        if (data.payments?.onlineEnabled && data.payments.keyId) {
            upiOption.classList.remove('hidden');
            upiOption.classList.add('flex');
        } else {
            upiOption.classList.add('hidden');
            upiOption.classList.remove('flex');
        }

        byId('delivery').textContent = formatRupees(state.settings.delivery_fee);
        const taxPercent = Number(state.settings.tax_rate) * 100;
        byId('tax-label').textContent = `Tax (${Number.isInteger(taxPercent) ? taxPercent : taxPercent.toFixed(2)}%)`;
        showMenuNotice('');
        renderCategories();
        renderMenu();
        renderPosters();
        renderCart();
    } catch (error) {
        state.menu = [];
        state.posters = [];
        state.settings = null;
        renderCategories();
        renderMenu();
        renderPosters();
        renderCart();
        showMenuNotice(`Restaurant data could not be loaded: ${error.message}`, true, true);
    }
}

function calculateTotals() {
    if (!state.settings) return null;
    const subtotalCents = state.cart.reduce(
        (sum, item) => sum + Math.round(Number(item.price) * 100) * item.qty,
        0
    );
    const taxRateBasisPoints = Math.round(Number(state.settings.tax_rate) * 10000);
    const taxCents = Math.floor((subtotalCents * taxRateBasisPoints + 5000) / 10000);
    const deliveryCents = Math.round(Number(state.settings.delivery_fee) * 100);
    return {
        subtotal: subtotalCents / 100,
        tax: taxCents / 100,
        delivery: deliveryCents / 100,
        total: (subtotalCents + taxCents + deliveryCents) / 100
    };
}

function renderCart() {
    byId('basket-count').textContent = String(
        state.cart.reduce((count, item) => count + item.qty, 0)
    );
    byId('cart-items').innerHTML = state.cart.length ? state.cart.map(item => `
        <div class="flex items-center justify-between gap-3 rounded-xl border bg-white p-3">
            <div class="flex min-w-0 items-center gap-3">
                <img src="${escapeHtml(item.image)}" alt="" class="h-12 w-12 rounded-lg object-cover">
                <div class="min-w-0">
                    <p class="truncate text-sm font-bold">${escapeHtml(item.name)}</p>
                    <p class="text-xs text-gray-500">${formatRupees(item.price)} each</p>
                </div>
            </div>
            <div class="flex shrink-0 items-center gap-2">
                <button type="button" data-qty-item="${item.id}" data-qty-delta="-1" class="h-7 w-7 rounded-lg border" aria-label="Remove one ${escapeHtml(item.name)}">−</button>
                <span class="min-w-4 text-center text-sm font-bold">${item.qty}</span>
                <button type="button" data-qty-item="${item.id}" data-qty-delta="1" class="h-7 w-7 rounded-lg border" aria-label="Add one ${escapeHtml(item.name)}">+</button>
            </div>
        </div>
    `).join('') : '<p class="py-12 text-center text-sm text-gray-500">Your basket is empty.</p>';

    const totals = calculateTotals();
    byId('subtotal').textContent = totals ? formatRupees(totals.subtotal) : '—';
    byId('tax').textContent = totals ? formatRupees(totals.tax) : '—';
    byId('delivery').textContent = state.settings ? formatRupees(state.settings.delivery_fee) : '—';
    byId('total').textContent = totals ? formatRupees(totals.total) : '—';
    byId('checkout-total').textContent = totals ? formatRupees(totals.total) : '—';
    byId('checkout-button').disabled = !state.cart.length || !totals;
}

function addToCart(id) {
    const item = state.menu.find(menuItem => Number(menuItem.id) === id);
    if (!item) return;
    const existing = state.cart.find(cartItem => cartItem.id === id);
    if (existing) existing.qty += 1;
    else state.cart.push({ ...item, id, qty: 1 });
    renderCart();
}

function openCart() {
    byId('cart-modal').classList.remove('hidden');
}

function closeCart() {
    byId('cart-modal').classList.add('hidden');
}

function openCheckout() {
    if (!state.cart.length || !calculateTotals()) return;
    closeCart();
    byId('checkout-error').classList.add('hidden');
    byId('checkout-modal').classList.remove('hidden');
    byId('checkout-modal').classList.add('flex');
    byId('customer-name').focus();
}

function closeCheckout() {
    byId('checkout-modal').classList.add('hidden');
    byId('checkout-modal').classList.remove('flex');
}

function showCheckoutError(message) {
    const error = byId('checkout-error');
    error.textContent = message;
    error.classList.remove('hidden');
}

async function loadRazorpay() {
    if (window.Razorpay) return;
    await new Promise((resolve, reject) => {
        const script = document.createElement('script');
        script.src = 'https://checkout.razorpay.com/v1/checkout.js';
        script.onload = resolve;
        script.onerror = () => reject(new Error('Online payment could not be loaded.'));
        document.head.append(script);
    });
}

function orderItems() {
    return state.cart.map(item => ({ menuItemId: item.id, qty: item.qty }));
}

function checkoutDetails(paymentMethod, razorpayPayment) {
    return {
        name: byId('customer-name').value.trim(),
        phone: byId('customer-phone').value.trim(),
        address: byId('customer-address').value.trim(),
        paymentMethod,
        items: orderItems(),
        ...(razorpayPayment ? { razorpayPayment } : {})
    };
}

async function submitOrder(paymentMethod, razorpayPayment) {
    const button = byId('place-order');
    button.disabled = true;
    try {
        const result = await apiRequest('/api/orders', {
            method: 'POST',
            body: checkoutDetails(paymentMethod, razorpayPayment)
        });
        state.cart = [];
        renderCart();
        closeCheckout();
        byId('confirmation-order-id').textContent = `Order #${result.order.id}`;
        byId('confirmation-total').textContent = `Total: ${formatRupees(result.order.total)}`;
        byId('confirmation-modal').classList.remove('hidden');
        byId('confirmation-modal').classList.add('flex');
    } catch (error) {
        showCheckoutError(error.message);
    } finally {
        button.disabled = false;
    }
}

async function beginOnlinePayment(button) {
    await loadRazorpay();
    const paymentOrder = await apiRequest('/api/payments/razorpay/orders', {
        method: 'POST',
        body: { items: orderItems() }
    });
    const checkout = new window.Razorpay({
        key: paymentOrder.keyId,
        amount: paymentOrder.amount,
        currency: paymentOrder.currency,
        name: 'Sri Madhuram Family Restaurant',
        description: 'Guest order',
        order_id: paymentOrder.razorpayOrderId,
        prefill: {
            name: byId('customer-name').value.trim(),
            contact: byId('customer-phone').value.trim()
        },
        handler: payment => submitOrder('upi', {
            orderId: payment.razorpay_order_id,
            paymentId: payment.razorpay_payment_id,
            signature: payment.razorpay_signature
        }),
        modal: { ondismiss: () => { button.disabled = false; } },
        theme: { color: '#D32F2F' }
    });
    checkout.on('payment.failed', response => {
        showCheckoutError(response.error?.description || 'Online payment failed. You can try again or choose cash on delivery.');
        button.disabled = false;
    });
    checkout.open();
}

async function handleCheckout(event) {
    event.preventDefault();
    const form = event.currentTarget;
    if (!form.reportValidity()) return;
    const button = byId('place-order');
    const paymentMethod = new FormData(form).get('paymentMethod');
    byId('checkout-error').classList.add('hidden');
    button.disabled = true;

    try {
        if (paymentMethod === 'upi') {
            if (!state.onlinePayment?.onlineEnabled) {
                throw new Error('Online payment is unavailable. Choose cash on delivery.');
            }
            await beginOnlinePayment(button);
        } else {
            await submitOrder('cod');
        }
    } catch (error) {
        showCheckoutError(error.message);
        button.disabled = false;
    }
}

byId('category-list').addEventListener('click', event => {
    const button = event.target.closest('[data-category]');
    if (!button) return;
    state.selectedCategory = button.dataset.category;
    renderCategories();
    renderMenu();
});

byId('menu-grid').addEventListener('click', event => {
    const button = event.target.closest('[data-add-item]');
    if (!button) return;
    addToCart(Number(button.dataset.addItem));
    openCart();
});

byId('cart-items').addEventListener('click', event => {
    const button = event.target.closest('[data-qty-item]');
    if (!button) return;
    const itemId = Number(button.dataset.qtyItem);
    const item = state.cart.find(cartItem => cartItem.id === itemId);
    if (!item) return;
    item.qty += Number(button.dataset.qtyDelta);
    if (item.qty <= 0) state.cart = state.cart.filter(cartItem => cartItem.id !== itemId);
    renderCart();
});

byId('menu-search').addEventListener('input', renderMenu);
byId('open-cart').addEventListener('click', openCart);
byId('close-cart').addEventListener('click', closeCart);
byId('checkout-button').addEventListener('click', openCheckout);
byId('close-checkout').addEventListener('click', closeCheckout);
byId('checkout-form').addEventListener('submit', handleCheckout);
byId('close-confirmation').addEventListener('click', () => {
    byId('confirmation-modal').classList.add('hidden');
    byId('confirmation-modal').classList.remove('flex');
});

loadPublicData();
