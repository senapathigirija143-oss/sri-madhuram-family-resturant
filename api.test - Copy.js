const { after, before, test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { createApiApp, validators, helpers } = require('./api');

let server;
let baseUrl;
let temporaryDirectory;
let storePath;
let accountsPath;

before(async () => {
    temporaryDirectory = await fs.mkdtemp(path.join(os.tmpdir(), 'restaurant-api-test-'));
    storePath = path.join(temporaryDirectory, 'store.json');
    accountsPath = path.join(temporaryDirectory, 'customers.json');
    await fs.writeFile(storePath, JSON.stringify({
        menu: [
            {
                id: 1,
                name: 'Local test dish',
                category: 'Test',
                price: 100,
                image: 'https://example.com/dish.jpg',
                description: 'A test dish'
            },
            {
                id: 2,
                name: 'Hidden test dish',
                category: 'Test',
                price: 200,
                image: 'https://example.com/hidden.jpg',
                description: '',
                is_available: false
            }
        ],
        posters: [],
        orders: [{ id: 'existing-order', status: 'Pending' }]
    }, null, 2));
    const app = createApiApp({
        storePath,
        accountsPath,
        adminAccount: { email: 'admin@example.com', password: 'demo-admin-password' },
        staffAccount: { email: 'staff@example.com', password: 'demo-staff-password' },
        deliveryFee: 30,
        taxRate: 0.1
    });
    server = app.listen(0);
    await new Promise(resolve => server.once('listening', resolve));
    baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
    if (server) {
        await new Promise((resolve, reject) => {
            server.close(error => error ? reject(error) : resolve());
        });
    }
    if (temporaryDirectory) {
        await fs.rm(temporaryDirectory, { recursive: true, force: true });
    }
});

test('health and public data use local JSON without adding sample data', async () => {
    const health = await fetch(`${baseUrl}/api/health`);
    assert.equal(health.status, 200);
    assert.deepEqual(await health.json(), { ok: true });

    const response = await fetch(`${baseUrl}/api/public-data`);
    assert.equal(response.status, 200);
    const data = await response.json();
    assert.deepEqual(data.menu.map(item => item.name), ['Local test dish']);
    assert.deepEqual(data.posters, []);
    assert.deepEqual(data.settings, { delivery_fee: 30, tax_rate: 0.1 });
    assert.equal(data.payments.onlineEnabled, false);

    const saved = JSON.parse(await fs.readFile(storePath, 'utf8'));
    assert.equal(saved.menu.length, 2);
    assert.equal(saved.orders.length, 1);
    assert.equal(saved.orders[0].id, 'existing-order');
});

test('guest cash-on-delivery orders are repriced from the saved menu and persisted', async () => {
    const response = await fetch(`${baseUrl}/api/orders`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            name: 'Guest Customer',
            phone: '9876543210',
            address: '1 Test Street',
            paymentMethod: 'cod',
            items: [{ menuItemId: 1, qty: 2, price: 0.01 }],
            total: 0.01
        })
    });
    assert.equal(response.status, 201);
    const { order } = await response.json();
    assert.match(order.id, /^ORD-\d{6}$/);
    assert.equal(order.subtotal, 200);
    assert.equal(order.tax, 20);
    assert.equal(order.delivery, 30);
    assert.equal(order.total, 250);
    assert.equal(order.paymentStatus, 'pending');
    assert.deepEqual(order.items, [{
        menuItemId: 1,
        name: 'Local test dish',
        qty: 2,
        price: 100
    }]);

    const saved = JSON.parse(await fs.readFile(storePath, 'utf8'));
    assert.equal(saved.orders.length, 2);
    assert.equal(saved.orders[0].id, order.id);
    assert.equal(saved.orders[1].id, 'existing-order');
});

test('concurrent guest orders are serialized without losing prior records', async () => {
    const makeRequest = suffix => fetch(`${baseUrl}/api/orders`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            name: `Guest ${suffix}`,
            phone: '9876543210',
            address: `${suffix} Test Street`,
            paymentMethod: 'cod',
            items: [{ menuItemId: 1, qty: 1 }]
        })
    });
    const responses = await Promise.all([makeRequest('A'), makeRequest('B')]);
    assert.deepEqual(responses.map(response => response.status), [201, 201]);
    const saved = JSON.parse(await fs.readFile(storePath, 'utf8'));
    assert.equal(saved.orders.length, 4);
    const newOrderIds = saved.orders.slice(0, 2).map(order => order.id);
    assert.ok(newOrderIds.every(id => /^ORD-\d{6}$/.test(id)));
    assert.equal(new Set(newOrderIds).size, 2);
    assert.deepEqual(saved.orders.slice(-1).map(order => order.id), ['existing-order']);
});

test('online guest payments are verified and payment retries are idempotent', async () => {
    const previousKeyId = process.env.RAZORPAY_KEY_ID;
    const previousSecret = process.env.RAZORPAY_KEY_SECRET;
    const originalFetch = global.fetch;
    const items = [{ menuItemId: 1, qty: 1 }];
    const itemHash = helpers.itemsHash(items);
    const gatewayOrder = {
        id: 'order_test123',
        amount: 14000,
        currency: 'INR',
        notes: { items_hash: itemHash }
    };
    process.env.RAZORPAY_KEY_ID = 'rzp_test';
    process.env.RAZORPAY_KEY_SECRET = 'test-secret';
    global.fetch = async input => {
        const url = new URL(typeof input === 'string' ? input : input.url);
        const result = url.pathname.endsWith('/payments/pay_test123')
            ? {
                order_id: gatewayOrder.id,
                status: 'captured',
                currency: 'INR',
                amount: gatewayOrder.amount
            }
            : gatewayOrder;
        return new Response(JSON.stringify(result), {
            status: 200,
            headers: { 'Content-Type': 'application/json' }
        });
    };

    try {
        const paymentOrderResponse = await originalFetch(`${baseUrl}/api/payments/razorpay/orders`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ items })
        });
        assert.equal(paymentOrderResponse.status, 201);
        const paymentOrder = await paymentOrderResponse.json();
        assert.equal(paymentOrder.amount, gatewayOrder.amount);

        const orderId = gatewayOrder.id;
        const paymentId = 'pay_test123';
        const signature = crypto.createHmac('sha256', 'test-secret')
            .update(`${orderId}|${paymentId}`)
            .digest('hex');
        const requestBody = {
            name: 'Online Guest',
            phone: '9876543210',
            address: '2 Test Street',
            paymentMethod: 'upi',
            items,
            razorpayPayment: { orderId, paymentId, signature }
        };
        const createResponse = await originalFetch(`${baseUrl}/api/orders`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(requestBody)
        });
        assert.equal(createResponse.status, 201);
        const { order } = await createResponse.json();
        assert.equal(order.paymentStatus, 'paid');

        const retryResponse = await originalFetch(`${baseUrl}/api/orders`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(requestBody)
        });
        assert.equal(retryResponse.status, 200);
        assert.equal((await retryResponse.json()).order.id, order.id);
        const saved = JSON.parse(await fs.readFile(storePath, 'utf8'));
        assert.equal(saved.orders.filter(savedOrder => savedOrder.paymentId === paymentId).length, 1);
    } finally {
        global.fetch = originalFetch;
        if (previousKeyId === undefined) delete process.env.RAZORPAY_KEY_ID;
        else process.env.RAZORPAY_KEY_ID = previousKeyId;
        if (previousSecret === undefined) delete process.env.RAZORPAY_KEY_SECRET;
        else process.env.RAZORPAY_KEY_SECRET = previousSecret;
    }
});

test('orders reject unavailable dishes and malformed input without changing saved orders', async () => {
    const before = JSON.parse(await fs.readFile(storePath, 'utf8'));
    const unavailable = await fetch(`${baseUrl}/api/orders`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            name: 'Guest Customer',
            phone: '9876543210',
            address: '1 Test Street',
            paymentMethod: 'cod',
            items: [{ menuItemId: 2, qty: 1 }]
        })
    });
    assert.equal(unavailable.status, 409);

    const invalid = await fetch(`${baseUrl}/api/orders`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({})
    });
    assert.equal(invalid.status, 400);
    const after = JSON.parse(await fs.readFile(storePath, 'utf8'));
    assert.deepEqual(after.orders, before.orders);
});

test('customers can register, sign in, place linked orders, and only see their own orders', async () => {
    const registration = await fetch(`${baseUrl}/api/customer/register`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            name: 'Demo Customer',
            phone: '9876543210',
            email: 'demo@example.com',
            password: 'customer-demo-password'
        })
    });
    assert.equal(registration.status, 201);

    const login = await fetch(`${baseUrl}/api/customer/login`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ phone: '9876543210', password: 'customer-demo-password' })
    });
    assert.equal(login.status, 200);
    const session = await login.json();
    assert.equal(session.customer.name, 'Demo Customer');
    assert.ok(session.accessToken);
    assert.ok(session.refreshToken);

    const headers = {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${session.accessToken}`
    };
    const adminData = await fetch(`${baseUrl}/api/admin/data`, { headers });
    assert.equal(adminData.status, 403);

    const oldOrders = await fetch(`${baseUrl}/api/customer/orders`, { headers });
    assert.equal(oldOrders.status, 200);
    assert.deepEqual((await oldOrders.json()).orders, []);

    const placed = await fetch(`${baseUrl}/api/orders`, {
        method: 'POST',
        headers,
        body: JSON.stringify({
            name: 'Demo Customer',
            phone: '9876543210',
            address: '3 Test Street',
            paymentMethod: 'cod',
            items: [{ menuItemId: 1, qty: 1 }]
        })
    });
    assert.equal(placed.status, 201);
    const { order } = await placed.json();
    assert.equal(order.customerId, session.customer.id);

    const cancellationRequest = await fetch(
        `${baseUrl}/api/customer/orders/${encodeURIComponent(order.id)}/cancellation-request`,
        { method: 'POST', headers }
    );
    assert.equal(cancellationRequest.status, 200);
    const requestResult = await cancellationRequest.json();
    assert.equal(requestResult.order.status, 'Pending');
    assert.equal(requestResult.order.cancellationRequest.status, 'pending');
    assert.ok(requestResult.order.cancellationRequest.requestedAt);
    assert.match(requestResult.message, /remains active/);

    const duplicateRequest = await fetch(
        `${baseUrl}/api/customer/orders/${encodeURIComponent(order.id)}/cancellation-request`,
        { method: 'POST', headers }
    );
    assert.equal(duplicateRequest.status, 200);
    assert.equal(
        (await duplicateRequest.json()).order.cancellationRequest.requestedAt,
        requestResult.order.cancellationRequest.requestedAt
    );

    const ownOrders = await fetch(`${baseUrl}/api/customer/orders`, { headers });
    const ownOrder = (await ownOrders.json()).orders[0];
    assert.equal(ownOrder.id, order.id);
    assert.equal(ownOrder.cancellationRequest.status, 'pending');

    const adminLogin = await fetch(`${baseUrl}/api/admin/login`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: 'admin@example.com', password: 'demo-admin-password' })
    });
    const adminSession = await adminLogin.json();
    const adminOrderResponse = await fetch(`${baseUrl}/api/admin/data`, {
        headers: { Authorization: `Bearer ${adminSession.accessToken}` }
    });
    const adminOrder = (await adminOrderResponse.json()).orders.find(item => item.id === order.id);
    assert.equal(adminOrder.cancellationRequest.status, 'pending');
    const staffLogin = await fetch(`${baseUrl}/api/staff/login`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: 'staff@example.com', password: 'demo-staff-password' })
    });
    const staffSession = await staffLogin.json();
    const staffReview = await fetch(
        `${baseUrl}/api/admin/orders/${encodeURIComponent(order.id)}/cancellation-request`,
        {
            method: 'PATCH',
            headers: {
                'Content-Type': 'application/json',
                Authorization: `Bearer ${staffSession.accessToken}`
            },
            body: JSON.stringify({ decision: 'denied' })
        }
    );
    assert.equal(staffReview.status, 403);
    const adminHeaders = {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${adminSession.accessToken}`
    };
    const deniedResponse = await fetch(
        `${baseUrl}/api/admin/orders/${encodeURIComponent(order.id)}/cancellation-request`,
        { method: 'PATCH', headers: adminHeaders, body: JSON.stringify({ decision: 'denied' }) }
    );
    assert.equal(deniedResponse.status, 200);
    const deniedOrder = (await deniedResponse.json()).order;
    assert.equal(deniedOrder.status, 'Pending');
    assert.equal(deniedOrder.cancellationRequest.status, 'denied');
    assert.equal(deniedOrder.cancellationRequest.reviewedBy, 'local-admin');
    assert.ok(deniedOrder.cancellationRequest.reviewedAt);

    const secondOrderResponse = await fetch(`${baseUrl}/api/orders`, {
        method: 'POST',
        headers,
        body: JSON.stringify({
            name: 'Demo Customer',
            phone: '9876543210',
            address: '4 Test Street',
            paymentMethod: 'cod',
            items: [{ menuItemId: 1, qty: 1 }]
        })
    });
    const secondOrder = (await secondOrderResponse.json()).order;
    const secondCancellation = await fetch(
        `${baseUrl}/api/customer/orders/${encodeURIComponent(secondOrder.id)}/cancellation-request`,
        { method: 'POST', headers }
    );
    assert.equal(secondCancellation.status, 200);
    const acceptedResponse = await fetch(
        `${baseUrl}/api/admin/orders/${encodeURIComponent(secondOrder.id)}/cancellation-request`,
        { method: 'PATCH', headers: adminHeaders, body: JSON.stringify({ decision: 'accepted' }) }
    );
    assert.equal(acceptedResponse.status, 200);
    const acceptedOrder = (await acceptedResponse.json()).order;
    assert.equal(acceptedOrder.status, 'Cancelled');
    assert.equal(acceptedOrder.cancellationRequest.status, 'accepted');

    const logout = await fetch(`${baseUrl}/api/auth/logout`, { method: 'POST', headers });
    assert.equal(logout.status, 200);
    const expired = await fetch(`${baseUrl}/api/customer/orders`, { headers });
    assert.equal(expired.status, 401);
});

test('staff and admin access is available only through configured local credentials', async () => {
    const login = await fetch(`${baseUrl}/api/admin/login`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: 'admin@example.com', password: 'demo-admin-password' })
    });
    assert.equal(login.status, 200);
    const session = await login.json();
    const protectedResponse = await fetch(`${baseUrl}/api/admin/data`, {
        headers: { Authorization: `Bearer ${session.accessToken}` }
    });
    assert.equal(protectedResponse.status, 200);

    const badLogin = await fetch(`${baseUrl}/api/staff/login`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: 'staff@example.com', password: 'wrong-password' })
    });
    assert.equal(badLogin.status, 401);
});

test('standalone OTP and cancellation/refund endpoints are absent', async () => {
    for (const [url, method, expectedStatus] of [
        ['/api/send-otp', 'POST', 404],
        ['/api/verify-otp', 'POST', 404],
        ['/api/customer/orders/ORD-1/cancel', 'POST', 404],
        ['/api/customer/orders/ORD-1/cancellation-preview', 'GET', 404],
        ['/api/admin/orders/ORD-1/refund/verify', 'POST', 404]
    ]) {
        const response = await fetch(`${baseUrl}${url}`, { method });
        assert.equal(response.status, expectedStatus, `${method} ${url}`);
        if (expectedStatus === 404) {
            assert.deepEqual(await response.json(), { error: 'API route not found.' });
        }
    }
    const unauthenticated = await fetch(`${baseUrl}/api/admin/data`);
    assert.equal(unauthenticated.status, 401);
    const unauthenticatedRequest = await fetch(
        `${baseUrl}/api/customer/orders/ORD-0123456789ABCDEF/cancellation-request`,
        { method: 'POST' }
    );
    assert.equal(unauthenticatedRequest.status, 401);
});

test('delivery requires the six-digit order number as OTP before marking delivered', async () => {
    const placed = await fetch(`${baseUrl}/api/orders`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            name: 'Delivery OTP Customer',
            phone: '9876543210',
            address: '5 Test Street',
            paymentMethod: 'cod',
            items: [{ menuItemId: 1, qty: 1 }]
        })
    });
    assert.equal(placed.status, 201);
    const { order } = await placed.json();
    assert.match(order.id, /^ORD-\d{6}$/);

    const staffLogin = await fetch(`${baseUrl}/api/staff/login`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: 'staff@example.com', password: 'demo-staff-password' })
    });
    const staffSession = await staffLogin.json();
    const headers = {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${staffSession.accessToken}`
    };
    for (const status of ['Approved', 'Cooking', 'Out for Delivery']) {
        const response = await fetch(`${baseUrl}/api/admin/orders/${order.id}`, {
            method: 'PATCH',
            headers,
            body: JSON.stringify({ status })
        });
        assert.equal(response.status, 200);
    }

    const missingOtp = await fetch(`${baseUrl}/api/admin/orders/${order.id}`, {
        method: 'PATCH',
        headers,
        body: JSON.stringify({ status: 'Delivered' })
    });
    assert.equal(missingOtp.status, 400);

    const incorrectOtp = await fetch(`${baseUrl}/api/admin/orders/${order.id}`, {
        method: 'PATCH',
        headers,
        body: JSON.stringify({ status: 'Delivered', otp: '000000' })
    });
    assert.equal(incorrectOtp.status, 403);
    assert.deepEqual(await incorrectOtp.json(), { error: 'The delivery OTP is incorrect.' });

    const delivered = await fetch(`${baseUrl}/api/admin/orders/${order.id}`, {
        method: 'PATCH',
        headers,
        body: JSON.stringify({ status: 'Delivered', otp: order.id.slice(4) })
    });
    assert.equal(delivered.status, 200);
    assert.equal((await delivered.json()).order.status, 'Delivered');

    for (const status of ['Approved', 'Cooking', 'Out for Delivery', 'Delivered']) {
        const legacyOrderUpdate = await fetch(`${baseUrl}/api/admin/orders/existing-order`, {
            method: 'PATCH',
            headers,
            body: JSON.stringify({ status })
        });
        assert.equal(legacyOrderUpdate.status, 200);
    }
});

test('malformed JSON and unknown API routes return clean JSON errors', async () => {
    const malformed = await fetch(`${baseUrl}/api/orders`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: '{invalid'
    });
    assert.equal(malformed.status, 400);
    assert.deepEqual(await malformed.json(), { error: 'Request body is not valid JSON.' });

    const unknown = await fetch(`${baseUrl}/api/not-a-route`);
    assert.equal(unknown.status, 404);
    assert.deepEqual(await unknown.json(), { error: 'API route not found.' });
});

test('order validators reject duplicate IDs and invalid locations', () => {
    assert.equal(validators.validOrderId('ORD-123456'), true);
    assert.equal(validators.validOrderId('ORD-1001'), false);
    assert.equal(validators.validOrderId('ORD-0123456789ABCDEF'), false);
    assert.equal(validators.validOrderId(null), false);
    assert.equal(validators.validOrderItems([
        { menuItemId: 1, qty: 1 },
        { menuItemId: 1, qty: 2 }
    ]), false);
    assert.equal(validators.validOrder({
        name: 'Guest',
        phone: '9876543210',
        address: 'Delivery address',
        paymentMethod: 'cod',
        items: [{ menuItemId: 1, qty: 1 }],
        location: { latitude: 91, longitude: 0, accuracy: 10, capturedAt: new Date().toISOString() }
    }), false);
});

test('restored portal retains categories and provides local sign-in and registration', async () => {
    const html = await fs.readFile(path.join(__dirname, 'index.html'), 'utf8');
    assert.match(html, /id="category-visual-list"/);
    assert.match(html, /id="category-pills"/);
    assert.match(html, /id="auth-modal"/);
    assert.match(html, /id="header-cancel-order-btn"/);
    assert.match(html, /function requestOrderCancellation\(\)/);
    assert.match(html, /function reviewCancellationRequest\(orderId, decision\)/);
    assert.match(html, /Delivery OTP/);
    assert.match(html, /id="signin-form" onsubmit="handleSignin\(event\)"/);
    assert.match(html, /id="reg-form" onsubmit="handleRegister\(event\)"/);
    assert.match(html, /id="customer-portal"/);
    assert.match(html, /id="staff-portal"/);
    assert.match(html, /id="admin-portal"/);
    assert.doesNotMatch(html, /send-otp|verify-otp|cancel-order-modal|10% of food subtotal|Supabase/i);
});
