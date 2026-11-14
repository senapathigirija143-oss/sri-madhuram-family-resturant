const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const path = require('node:path');
const express = require('express');
const multer = require('multer');
const { promisify } = require('node:util');
const { createLocalAccountsStore, createLocalStore } = require('./local-store');

const orderStatuses = ['Pending', 'Approved', 'Cooking', 'Out for Delivery', 'Delivered'];
const rateBuckets = new Map();
const defaultStorePath = path.join(__dirname, '.restaurant-data', 'store.json');
const defaultAccountsPath = path.join(__dirname, '.restaurant-data', 'customers.json');
const defaultImageUploadDirectory = path.join(__dirname, 'uploads', 'menu');
const imageMimeExtensions = {
    'image/jpeg': '.jpg',
    'image/png': '.png',
    'image/webp': '.webp'
};
const maxMenuImageSize = 5 * 1024 * 1024;
const scrypt = promisify(crypto.scrypt);

function apiError(message, statusCode = 500) {
    const error = new Error(message);
    error.statusCode = statusCode;
    return error;
}

function asyncRoute(handler) {
    return (req, res, next) => Promise.resolve(handler(req, res, next)).catch(next);
}

function requireBody(condition, message) {
    if (!condition) throw apiError(message, 400);
}

function rateLimit(name, max, windowMs) {
    return (req, res, next) => {
        const now = Date.now();
        const key = `${name}:${req.ip}`;
        const bucket = rateBuckets.get(key);
        if (!bucket || bucket.resetAt <= now) {
            rateBuckets.set(key, { count: 1, resetAt: now + windowMs });
            return next();
        }
        bucket.count += 1;
        if (bucket.count > max) {
            res.set('Retry-After', String(Math.ceil((bucket.resetAt - now) / 1000)));
            return next(apiError('Too many requests. Please wait and try again.', 429));
        }
        next();
    };
}

setInterval(() => {
    const now = Date.now();
    for (const [key, bucket] of rateBuckets) {
        if (bucket.resetAt <= now) rateBuckets.delete(key);
    }
}, 10 * 60 * 1000).unref();

function validLocation(location) {
    if (location === undefined || location === null) return true;
    return Boolean(location &&
        Number.isFinite(location.latitude) &&
        location.latitude >= -90 &&
        location.latitude <= 90 &&
        Number.isFinite(location.longitude) &&
        location.longitude >= -180 &&
        location.longitude <= 180 &&
        Number.isFinite(location.accuracy) &&
        location.accuracy > 0 &&
        location.accuracy <= 100000 &&
        typeof location.capturedAt === 'string' &&
        Number.isFinite(Date.parse(location.capturedAt)));
}

function validOrderItems(items) {
    return Array.isArray(items) &&
        items.length > 0 &&
        items.length <= 50 &&
        items.every(item =>
            item &&
            Number.isSafeInteger(item.menuItemId) &&
            item.menuItemId > 0 &&
            Number.isInteger(item.qty) &&
            item.qty > 0 &&
            item.qty <= 100
        ) &&
        new Set(items.map(item => item.menuItemId)).size === items.length;
}

function validOrder(order) {
    return Boolean(order &&
        typeof order.name === 'string' &&
        order.name.trim().length > 0 &&
        order.name.length <= 100 &&
        typeof order.phone === 'string' &&
        /^[0-9+ -]{7,20}$/.test(order.phone) &&
        (order.phone.match(/\d/g) || []).length >= 7 &&
        typeof order.address === 'string' &&
        order.address.trim().length > 0 &&
        order.address.length <= 500 &&
        ['upi', 'cod'].includes(order.paymentMethod) &&
        validOrderItems(order.items) &&
        validLocation(order.location));
}

function validOrderId(id) {
    return typeof id === 'string' && /^ORD-\d{6}$/.test(id);
}

function createOrderId(orders) {
    const existingIds = new Set(orders.map(order => String(order.id)));
    for (let attempt = 0; attempt < 100; attempt += 1) {
        const id = `ORD-${crypto.randomInt(100000, 1000000)}`;
        if (!existingIds.has(id)) return id;
    }
    throw apiError('A unique six-digit order number could not be generated. Try again.', 503);
}

function itemsHash(items) {
    const canonical = [...items]
        .sort((left, right) => left.menuItemId - right.menuItemId)
        .map(item => ({ menuItemId: item.menuItemId, qty: item.qty }));
    return crypto.createHash('sha256').update(JSON.stringify(canonical)).digest('hex');
}

function parsePricing(value, fallback, label, maximum) {
    const parsed = value === undefined ? fallback : Number(value);
    if (!Number.isFinite(parsed) || parsed < 0 || parsed > maximum) {
        throw apiError(`The configured ${label} is invalid.`, 503);
    }
    return parsed;
}

function validEmail(value) {
    return typeof value === 'string' &&
        value.length <= 254 &&
        /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}

function validPassword(value) {
    return typeof value === 'string' && value.length >= 8 && value.length <= 128;
}

function validMenu(items) {
    return Array.isArray(items) &&
        items.length <= 500 &&
        items.every(item =>
            item &&
            Number.isSafeInteger(item.id) &&
            item.id > 0 &&
            typeof item.name === 'string' &&
            item.name.trim().length > 0 &&
            item.name.length <= 100 &&
            typeof item.category === 'string' &&
            item.category.trim().length > 0 &&
            item.category.length <= 60 &&
            Number.isFinite(item.price) &&
            item.price > 0 &&
            item.price <= 100000 &&
            Math.round(item.price * 100) === item.price * 100 &&
            typeof item.image === 'string' &&
            (isHttpUrl(item.image) || isMenuImagePath(item.image)) &&
            (item.description === undefined ||
                (typeof item.description === 'string' && item.description.length <= 300))
        );
}

function isMenuImagePath(value) {
    return /^\/uploads\/menu\/[a-f0-9]{32}\.(?:jpg|png|webp)$/.test(value);
}

function hasImageSignature(buffer, mimeType) {
    if (mimeType === 'image/jpeg') {
        return buffer.length >= 3 &&
            buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff;
    }
    if (mimeType === 'image/png') {
        return buffer.length >= 8 &&
            buffer.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
    }
    if (mimeType === 'image/webp') {
        return buffer.length >= 12 &&
            buffer.toString('ascii', 0, 4) === 'RIFF' &&
            buffer.toString('ascii', 8, 12) === 'WEBP';
    }
    return false;
}

function isHttpUrl(value) {
    try {
        return ['http:', 'https:'].includes(new URL(value).protocol);
    } catch {
        return false;
    }
}

function validPosters(posters) {
    return Array.isArray(posters) &&
        posters.length <= 100 &&
        posters.every(poster =>
            poster &&
            Number.isSafeInteger(poster.id) &&
            poster.id > 0 &&
            typeof poster.title === 'string' &&
            poster.title.trim().length > 0 &&
            poster.title.length <= 100 &&
            typeof poster.image === 'string' &&
            isHttpUrl(poster.image) &&
            (poster.description === undefined ||
                (typeof poster.description === 'string' && poster.description.length <= 300))
        );
}

function normalizeOrder(order) {
    return {
        ...order,
        paymentMethod: order.paymentMethod || String(order.payment || 'cod').toLowerCase(),
        payment: order.payment || String(order.paymentMethod || 'cod').toUpperCase(),
        items: Array.isArray(order.items) ? order.items : []
    };
}

function safeOrderId(value) {
    return typeof value === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(value);
}

function bearerToken(req) {
    const match = (req.get('authorization') || '').match(/^Bearer\s+(.+)$/i);
    return match ? match[1] : '';
}

async function passwordHash(password, salt) {
    return scrypt(password, salt, 64);
}

function createApiApp(options = {}) {
    const app = express();
    const store = createLocalStore(options.storePath || defaultStorePath);
    const accounts = createLocalAccountsStore(options.accountsPath || defaultAccountsPath);
    const imageUploadDirectory = options.imageUploadDirectory || defaultImageUploadDirectory;
    const imageUpload = multer({
        storage: multer.memoryStorage(),
        limits: { fileSize: maxMenuImageSize, files: 1, fields: 0, parts: 1 },
        fileFilter(req, file, callback) {
            if (!Object.hasOwn(imageMimeExtensions, file.mimetype)) {
                return callback(apiError('Choose a JPG, PNG, or WEBP image.', 400));
            }
            callback(null, true);
        }
    });
    const sessions = new Map();
    const sessionsByRefresh = new Map();
    const configuredAccounts = {
        admin: options.adminAccount || {
            email: process.env.LOCAL_ADMIN_EMAIL,
            password: process.env.LOCAL_ADMIN_PASSWORD
        },
        staff: options.staffAccount || {
            email: process.env.LOCAL_STAFF_EMAIL,
            password: process.env.LOCAL_STAFF_PASSWORD
        }
    };
    const deliveryFee = parsePricing(
        options.deliveryFee ?? process.env.RESTAURANT_DELIVERY_FEE,
        30,
        'delivery fee',
        100000
    );
    const taxRate = parsePricing(
        options.taxRate ?? process.env.RESTAURANT_TAX_RATE,
        0.1,
        'tax rate',
        1
    );

    app.disable('x-powered-by');
    if (process.env.TRUST_PROXY) {
        app.set('trust proxy', /^\d+$/.test(process.env.TRUST_PROXY)
            ? Number(process.env.TRUST_PROXY)
            : process.env.TRUST_PROXY);
    }
    app.use(express.json({ limit: '64kb' }));
    app.use('/uploads/menu', express.static(imageUploadDirectory, {
        dotfiles: 'deny',
        immutable: true,
        maxAge: '1y'
    }));

    function issueSession(user) {
        const accessToken = crypto.randomBytes(32).toString('base64url');
        const refreshToken = crypto.randomBytes(32).toString('base64url');
        const session = {
            user,
            accessExpiresAt: Date.now() + 12 * 60 * 60 * 1000,
            refreshExpiresAt: Date.now() + 7 * 24 * 60 * 60 * 1000
        };
        sessions.set(accessToken, session);
        sessionsByRefresh.set(refreshToken, { ...session, accessToken, refreshToken });
        return { accessToken, refreshToken };
    }

    function authenticatedUser(req) {
        const token = bearerToken(req);
        const session = sessions.get(token);
        if (!session || session.accessExpiresAt <= Date.now()) {
            if (session) sessions.delete(token);
            throw apiError('Sign in is required or your session expired.', 401);
        }
        return session.user;
    }

    function requireRole(...roles) {
        return (req, res, next) => {
            try {
                const user = authenticatedUser(req);
                if (!roles.includes(user.role)) {
                    throw apiError('You are not authorized to perform this action.', 403);
                }
                req.user = user;
                next();
            } catch (error) {
                next(error);
            }
        };
    }

    async function authenticateCustomer(identifier, password) {
        const normalizedIdentifier = String(identifier || '').trim().toLowerCase();
        const accountList = await accounts.read();
        const account = accountList.find(candidate =>
            candidate.phone === String(identifier || '').trim() ||
            candidate.email === normalizedIdentifier
        );
        if (!account || account.role !== 'customer') {
            throw apiError('Invalid mobile number/email or password.', 401);
        }
        const candidateHash = await passwordHash(password, account.passwordSalt);
        const expectedHash = Buffer.from(account.passwordHash, 'hex');
        if (candidateHash.length !== expectedHash.length ||
            !crypto.timingSafeEqual(candidateHash, expectedHash)) {
            throw apiError('Invalid mobile number/email or password.', 401);
        }
        return {
            id: account.id,
            email: account.email,
            phone: account.phone,
            name: account.name,
            role: 'customer'
        };
    }

    async function authenticateConfiguredRole(role, email, password) {
        const configured = configuredAccounts[role];
        if (!validEmail(configured?.email) || !validPassword(configured?.password)) {
            throw apiError(
                `Local ${role} sign-in is not configured. Set LOCAL_${role.toUpperCase()}_EMAIL and LOCAL_${role.toUpperCase()}_PASSWORD in .env.`,
                503
            );
        }

        const normalizedEmail = email.trim().toLowerCase();
        const salt = crypto.createHash('sha256')
            .update(`sri-madhuram-local-${role}:${configured.email.trim().toLowerCase()}`)
            .digest();
        const [candidateHash, expectedHash] = await Promise.all([
            passwordHash(password, salt),
            passwordHash(configured.password, salt)
        ]);
        if (
            normalizedEmail !== configured.email.trim().toLowerCase() ||
            candidateHash.length !== expectedHash.length ||
            !crypto.timingSafeEqual(candidateHash, expectedHash)
        ) {
            throw apiError(`Invalid ${role} email or password.`, 401);
        }

        return {
            id: `local-${role}`,
            email: normalizedEmail,
            phone: '',
            name: role === 'admin' ? 'Administrator' : 'Staff',
            role
        };
    }

    app.post('/api/customer/register', rateLimit('customer-register', 10, 15 * 60 * 1000),
        asyncRoute(async (req, res) => {
            const name = typeof req.body?.name === 'string' ? req.body.name.trim() : '';
            const phone = typeof req.body?.phone === 'string' ? req.body.phone.trim() : '';
            const email = typeof req.body?.email === 'string'
                ? req.body.email.trim().toLowerCase()
                : '';
            const password = req.body?.password;
            requireBody(
                name.length > 0 &&
                name.length <= 100 &&
                /^\d{10}$/.test(phone) &&
                validEmail(email) &&
                validPassword(password),
                'Enter a name, valid 10-digit mobile number, email, and password of at least 8 characters.'
            );

            const salt = crypto.randomBytes(16).toString('hex');
            const hash = (await passwordHash(password, salt)).toString('hex');
            const account = {
                id: crypto.randomUUID(),
                name,
                phone,
                email,
                role: 'customer',
                passwordSalt: salt,
                passwordHash: hash,
                createdAt: new Date().toISOString()
            };
            await accounts.update(accountList => {
                if (accountList.some(candidate =>
                    candidate.phone === phone || candidate.email === email
                )) {
                    throw apiError('This mobile number or email is already registered.', 409);
                }
                accountList.push(account);
            });
            res.status(201).json({
                success: true,
                message: 'Account created. You can now sign in.'
            });
        }));

    app.post('/api/customer/login', rateLimit('customer-login', 10, 15 * 60 * 1000),
        asyncRoute(async (req, res) => {
            const identifier = typeof req.body?.phone === 'string'
                ? req.body.phone
                : req.body?.email;
            const password = req.body?.password;
            requireBody(
                typeof identifier === 'string' &&
                identifier.trim().length <= 254 &&
                validPassword(password),
                'Enter your registered mobile number/email and password.'
            );
            const customer = await authenticateCustomer(identifier, password);
            res.json({
                success: true,
                ...issueSession(customer),
                customer
            });
        }));

    for (const role of ['admin', 'staff']) {
        app.post(`/api/${role}/login`, rateLimit(`${role}-login`, 10, 15 * 60 * 1000),
            asyncRoute(async (req, res) => {
                const email = typeof req.body?.email === 'string' ? req.body.email : '';
                const password = req.body?.password;
                requireBody(validEmail(email) && validPassword(password),
                    `Enter your ${role} email and password.`);
                const user = await authenticateConfiguredRole(role, email, password);
                res.json({
                    success: true,
                    ...issueSession(user),
                    [role]: { id: user.id, email: user.email }
                });
            }));
    }

    app.post('/api/auth/refresh', asyncRoute(async (req, res) => {
        const refreshToken = typeof req.body?.refreshToken === 'string'
            ? req.body.refreshToken
            : '';
        const session = sessionsByRefresh.get(refreshToken);
        if (!session || session.refreshExpiresAt <= Date.now()) {
            throw apiError('Your session expired. Please sign in again.', 401);
        }
        sessionsByRefresh.delete(refreshToken);
        sessions.delete(session.accessToken);
        res.json(issueSession(session.user));
    }));

    app.post('/api/auth/logout', (req, res) => {
        const accessToken = bearerToken(req);
        const session = sessions.get(accessToken);
        if (session) sessions.delete(accessToken);
        for (const [refreshToken, refreshSession] of sessionsByRefresh) {
            if (refreshSession.accessToken === accessToken) {
                sessionsByRefresh.delete(refreshToken);
            }
        }
        res.json({ ok: true });
    });

    app.get('/api/auth/me', (req, res, next) => {
        try {
            res.json({ user: authenticatedUser(req) });
        } catch (error) {
            next(error);
        }
    });

    async function readMenuPrices(items) {
        const data = await store.read();
        const menuById = new Map(data.menu
            .filter(item => Number.isSafeInteger(Number(item.id)) && Number(item.id) > 0)
            .map(item => [Number(item.id), item]));

        const selected = items.map(({ menuItemId, qty }) => {
            const menuItem = menuById.get(menuItemId);
            if (!menuItem || menuItem.is_available === false) {
                throw apiError('One or more menu items are no longer available.', 409);
            }
            const price = Number(menuItem.price);
            if (
                typeof menuItem.name !== 'string' ||
                !menuItem.name.trim() ||
                !Number.isFinite(price) ||
                price <= 0 ||
                price > 100000
            ) {
                throw apiError('A saved menu item has invalid data. Contact the restaurant.', 503);
            }
            return {
                id: menuItemId,
                name: String(menuItem.name),
                qty,
                priceCents: Math.round(price * 100)
            };
        });

        const subtotalCents = selected.reduce(
            (total, item) => total + BigInt(item.priceCents) * BigInt(item.qty),
            0n
        );
        const taxBasisPoints = BigInt(Math.round(taxRate * 10000));
        const taxCents = (subtotalCents * taxBasisPoints + 5000n) / 10000n;
        const deliveryCents = BigInt(Math.round(deliveryFee * 100));
        const totalCents = subtotalCents + taxCents + deliveryCents;
        if (totalCents <= 0n || totalCents > 100000000n) {
            throw apiError('The order total is outside the permitted range.', 400);
        }

        return {
            selected,
            subtotal: Number(subtotalCents) / 100,
            tax: Number(taxCents) / 100,
            delivery: Number(deliveryCents) / 100,
            total: Number(totalCents) / 100,
            totalCents: Number(totalCents)
        };
    }

    async function razorpayRequest(endpoint, body) {
        const keyId = process.env.RAZORPAY_KEY_ID;
        const keySecret = process.env.RAZORPAY_KEY_SECRET;
        if (!keyId || !keySecret) {
            throw apiError('Online payment is not configured. Choose cash on delivery.', 503);
        }

        const response = await fetch(`https://api.razorpay.com/v1${endpoint}`, {
            method: body ? 'POST' : 'GET',
            headers: {
                Authorization: `Basic ${Buffer.from(`${keyId}:${keySecret}`).toString('base64')}`,
                ...(body ? { 'Content-Type': 'application/json' } : {})
            },
            body: body ? JSON.stringify(body) : undefined
        });
        const result = await response.json().catch(() => ({}));
        if (!response.ok) {
            const message = result.error?.description || 'Online payment could not be completed.';
            throw apiError(message, response.status >= 500 ? 502 : 400);
        }
        return result;
    }

    function verifyRazorpaySignature(orderId, paymentId, signature) {
        const keySecret = process.env.RAZORPAY_KEY_SECRET;
        if (!keySecret || typeof signature !== 'string' || !/^[a-f0-9]{64}$/i.test(signature)) {
            return false;
        }
        const expected = crypto.createHmac('sha256', keySecret)
            .update(`${orderId}|${paymentId}`)
            .digest();
        const received = Buffer.from(signature, 'hex');
        return received.length === expected.length &&
            crypto.timingSafeEqual(received, expected);
    }

    app.get('/api/health', (req, res) => res.json({ ok: true }));

    app.get('/api/public-data', asyncRoute(async (req, res) => {
        const data = await store.read();
        const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
        res.json({
            menu: data.menu
                .filter(item => item.is_available !== false && Number(item.id) > 0)
                .map(item => ({
                    id: Number(item.id),
                    name: item.name,
                    category: item.category,
                    price: Number(item.price),
                    image: item.image,
                    description: item.description || ''
                })),
            posters: data.posters
                .filter(poster => poster.is_published !== false &&
                    (!poster.expires_at || poster.expires_at >= today))
                .map(poster => ({ ...poster, image: poster.image || poster.image_url })),
            settings: { delivery_fee: deliveryFee, tax_rate: taxRate },
            payments: {
                onlineEnabled: Boolean(
                    process.env.RAZORPAY_KEY_ID && process.env.RAZORPAY_KEY_SECRET
                ),
                keyId: process.env.RAZORPAY_KEY_ID || null
            }
        });
    }));

    app.get('/api/admin/data', requireRole('admin', 'staff'), asyncRoute(async (req, res) => {
        const data = await store.read();
        res.json({ orders: data.orders.map(normalizeOrder) });
    }));

    app.post('/api/customer/orders/:id/cancellation-request', requireRole('customer'),
        asyncRoute(async (req, res) => {
            const { id } = req.params;
            requireBody(safeOrderId(id), 'Order ID is invalid.');
            const order = await store.update(data => {
                const customerOrder = data.orders.find(candidate =>
                    String(candidate.id) === id && candidate.customerId === req.user.id
                );
                if (!customerOrder) throw apiError('Order was not found.', 404);
                if (!['Pending', 'Approved', 'Cooking', 'Out for Delivery'].includes(customerOrder.status)) {
                    throw apiError('A cancellation request cannot be submitted for this order status.', 409);
                }
                if (!customerOrder.cancellationRequest) {
                    customerOrder.cancellationRequest = {
                        status: 'pending',
                        requestedAt: new Date().toISOString()
                    };
                }
                return normalizeOrder(customerOrder);
            });
            res.json({
                message: 'Cancellation request sent to the restaurant. Your order remains active until staff reviews it.',
                order
            });
        }));

    app.patch('/api/admin/orders/:id/cancellation-request', requireRole('admin'),
        asyncRoute(async (req, res) => {
            const { id } = req.params;
            const decision = req.body?.decision;
            requireBody(safeOrderId(id), 'Order ID is invalid.');
            requireBody(['accepted', 'denied'].includes(decision),
                'Cancellation decision must be accepted or denied.');

            const order = await store.update(data => {
                const savedOrder = data.orders.find(candidate => String(candidate.id) === id);
                if (!savedOrder) throw apiError('Order was not found.', 404);
                if (savedOrder.cancellationRequest?.status !== 'pending') {
                    throw apiError('There is no pending cancellation request for this order.', 409);
                }
                if (decision === 'accepted') {
                    if (!['Pending', 'Approved', 'Cooking', 'Out for Delivery'].includes(savedOrder.status)) {
                        throw apiError('This order can no longer be cancelled.', 409);
                    }
                    savedOrder.status = 'Cancelled';
                }
                savedOrder.cancellationRequest = {
                    ...savedOrder.cancellationRequest,
                    status: decision,
                    reviewedAt: new Date().toISOString(),
                    reviewedBy: req.user.id
                };
                return normalizeOrder(savedOrder);
            });
            res.json({
                message: decision === 'accepted'
                    ? 'Cancellation request accepted. The order is cancelled; handle any refund separately.'
                    : 'Cancellation request denied. The order remains active.',
                order
            });
        }));

    app.get('/api/customer/orders', requireRole('customer'), asyncRoute(async (req, res) => {
        const data = await store.read();
        res.json({
            orders: data.orders
                .filter(order => order.customerId === req.user.id)
                .map(normalizeOrder)
        });
    }));

    app.post('/api/admin/menu/image-upload', requireRole('admin'),
        rateLimit('menu-image-upload', 30, 15 * 60 * 1000), (req, res, next) => {
            if (process.env.VERCEL) {
                return next(apiError(
                    'Image uploads are disabled on Vercel because local files are not persistent. Configure durable image storage before enabling uploads.',
                    503
                ));
            }
            next();
        }, imageUpload.single('image'), asyncRoute(async (req, res) => {
            requireBody(req.file, 'Select an image to upload.');
            if (!hasImageSignature(req.file.buffer, req.file.mimetype)) {
                throw apiError('The selected file is not a valid JPG, PNG, or WEBP image.', 400);
            }

            const extension = imageMimeExtensions[req.file.mimetype];
            const filename = `${crypto.randomBytes(16).toString('hex')}${extension}`;
            await fs.mkdir(imageUploadDirectory, { recursive: true });
            await fs.writeFile(path.join(imageUploadDirectory, filename), req.file.buffer, { flag: 'wx' });
            res.status(201).json({ image: `/uploads/menu/${filename}` });
        }));

    app.put('/api/admin/menu', requireRole('admin'), asyncRoute(async (req, res) => {
        const items = req.body?.items;
        requireBody(validMenu(items), 'Menu data is invalid.');
        const submittedIds = new Set(items.map(item => item.id));

        await store.update(data => {
            for (const existing of data.menu) {
                if (!submittedIds.has(Number(existing.id))) existing.is_available = false;
            }
            const menuById = new Map(data.menu.map(item => [Number(item.id), item]));
            for (const item of items) {
                const normalized = {
                    ...item,
                    id: Number(item.id),
                    image: item.image,
                    description: item.description || '',
                    is_available: true
                };
                const existing = menuById.get(normalized.id);
                if (existing) Object.assign(existing, normalized);
                else data.menu.push(normalized);
            }
        });

        const data = await store.read();
        res.json({
            menu: data.menu
                .filter(item => item.is_available !== false && Number(item.id) > 0)
                .map(item => ({
                    id: Number(item.id),
                    name: item.name,
                    category: item.category,
                    price: Number(item.price),
                    image: item.image || item.image_url,
                    description: item.description || ''
                }))
        });
    }));

    app.put('/api/admin/posters', requireRole('admin'), asyncRoute(async (req, res) => {
        const posters = req.body?.posters;
        requireBody(validPosters(posters), 'Poster data is invalid.');
        const submittedIds = new Set(posters.map(poster => poster.id));

        await store.update(data => {
            for (const existing of data.posters) {
                if (!submittedIds.has(Number(existing.id))) existing.is_published = false;
            }
            const posterById = new Map(data.posters.map(poster => [Number(poster.id), poster]));
            for (const poster of posters) {
                const normalized = {
                    ...poster,
                    id: Number(poster.id),
                    image: poster.image,
                    is_published: poster.is_published !== false
                };
                const existing = posterById.get(normalized.id);
                if (existing) Object.assign(existing, normalized);
                else data.posters.push(normalized);
            }
        });

        const data = await store.read();
        res.json({ posters: data.posters.filter(poster => poster.is_published !== false) });
    }));

    app.patch('/api/admin/orders/:id', requireRole('admin', 'staff'), asyncRoute(async (req, res) => {
        const { id } = req.params;
        const status = req.body?.status;
        requireBody(safeOrderId(id), 'Order ID is invalid.');
        requireBody(orderStatuses.includes(status), 'Order status is invalid.');
        const otp = req.body?.otp;
        if (status === 'Delivered' && validOrderId(id)) {
            requireBody(typeof otp === 'string' && /^\d{6}$/.test(otp),
                'A valid 6-digit delivery OTP is required.');
        }

        const order = await store.update(data => {
            const savedOrder = data.orders.find(candidate => String(candidate.id) === id);
            if (!savedOrder) throw apiError('Order was not found.', 404);
            const currentIndex = orderStatuses.indexOf(savedOrder.status);
            const nextIndex = orderStatuses.indexOf(status);
            if (currentIndex < 0 || nextIndex !== currentIndex + 1) {
                throw apiError('Order status can only move to the next step.', 409);
            }
            if (status === 'Delivered') {
                if (savedOrder.cancellationRequest?.status === 'pending') {
                    throw apiError('Review the pending cancellation request before marking this order delivered.', 409);
                }
                if (validOrderId(id) && otp !== id.slice(4)) {
                    throw apiError('The delivery OTP is incorrect.', 403);
                }
            }
            savedOrder.status = status;
            return normalizeOrder(savedOrder);
        });
        res.json({ order });
    }));

    app.post('/api/payments/razorpay/orders', rateLimit('payment-order', 10, 15 * 60 * 1000),
        asyncRoute(async (req, res) => {
            const items = req.body?.items;
            requireBody(validOrderItems(items), 'Order items are invalid.');
            const amount = await readMenuPrices(items);
            const keyId = process.env.RAZORPAY_KEY_ID;
            const razorpayOrder = await razorpayRequest('/orders', {
                amount: amount.totalCents,
                currency: 'INR',
                receipt: `sm-${crypto.randomUUID().replace(/-/g, '').slice(0, 32)}`,
                notes: { items_hash: itemsHash(items) }
            });
            if (
                !keyId ||
                !/^order_[A-Za-z0-9]+$/.test(razorpayOrder.id || '') ||
                Number(razorpayOrder.amount) !== amount.totalCents ||
                razorpayOrder.currency !== 'INR'
            ) {
                throw apiError('Online payment returned an invalid order.', 502);
            }
            res.status(201).json({
                keyId,
                razorpayOrderId: razorpayOrder.id,
                amount: razorpayOrder.amount,
                currency: 'INR'
            });
        }));

    app.post('/api/orders', rateLimit('guest-order', 10, 15 * 60 * 1000),
        asyncRoute(async (req, res) => {
            requireBody(validOrder(req.body), 'Order details are invalid.');
            const customer = bearerToken(req) ? authenticatedUser(req) : null;
            if (customer && customer.role !== 'customer') {
                throw apiError('Only customer accounts can place online orders.', 403);
            }
            const amount = await readMenuPrices(req.body.items);
            let paymentId = null;
            let paymentStatus = 'pending';

            if (req.body.paymentMethod === 'upi') {
                const payment = req.body.razorpayPayment || {};
                const paymentOrderId = typeof payment.orderId === 'string' ? payment.orderId : '';
                paymentId = typeof payment.paymentId === 'string' ? payment.paymentId : '';
                const signature = typeof payment.signature === 'string' ? payment.signature : '';
                requireBody(
                    /^order_[A-Za-z0-9]+$/.test(paymentOrderId) &&
                    /^pay_[A-Za-z0-9]+$/.test(paymentId) &&
                    verifyRazorpaySignature(paymentOrderId, paymentId, signature),
                    'Online payment verification failed.'
                );

                const [gatewayOrder, gatewayPayment] = await Promise.all([
                    razorpayRequest(`/orders/${encodeURIComponent(paymentOrderId)}`),
                    razorpayRequest(`/payments/${encodeURIComponent(paymentId)}`)
                ]);
                if (
                    gatewayOrder.id !== paymentOrderId ||
                    gatewayOrder.currency !== 'INR' ||
                    Number(gatewayOrder.amount) !== amount.totalCents ||
                    gatewayOrder.notes?.items_hash !== itemsHash(req.body.items) ||
                    gatewayPayment.order_id !== paymentOrderId ||
                    gatewayPayment.status !== 'captured' ||
                    gatewayPayment.currency !== 'INR' ||
                    Number(gatewayPayment.amount) !== amount.totalCents
                ) {
                    throw apiError('The payment gateway has not confirmed the full order amount.', 402);
                }
                paymentStatus = 'paid';
            }

            const order = {
                name: req.body.name.trim(),
                phone: req.body.phone.trim(),
                type: 'Delivery',
                subtotal: amount.subtotal,
                tax: amount.tax,
                delivery: amount.delivery,
                total: amount.total,
                paymentMethod: req.body.paymentMethod,
                payment: req.body.paymentMethod.toUpperCase(),
                paymentStatus,
                paymentId,
                customerId: customer?.id || null,
                status: 'Pending',
                address: req.body.address.trim(),
                latitude: req.body.location?.latitude ?? null,
                longitude: req.body.location?.longitude ?? null,
                locationAccuracy: req.body.location?.accuracy ?? null,
                locationCapturedAt: req.body.location?.capturedAt ?? null,
                createdAt: new Date().toISOString(),
                items: amount.selected.map(item => ({
                    menuItemId: item.id,
                    name: item.name,
                    qty: item.qty,
                    price: item.priceCents / 100
                }))
            };

            const saved = await store.update(data => {
                if (paymentId) {
                    const existingOrder = data.orders.find(existing => existing.paymentId === paymentId);
                    if (existingOrder) return { order: existingOrder, duplicate: true };
                }
                order.id = createOrderId(data.orders);
                data.orders.unshift(order);
                return { order, duplicate: false };
            });

            res.status(saved.duplicate ? 200 : 201).json({ order: saved.order });
        }));

    app.use('/api', (req, res, next) => next(apiError('API route not found.', 404)));

    app.use((error, req, res, next) => {
        if (error.type === 'entity.parse.failed') {
            error = apiError('Request body is not valid JSON.', 400);
        } else if (error.type === 'entity.too.large') {
            error = apiError('Request is too large.', 413);
        } else if (error instanceof multer.MulterError && error.code === 'LIMIT_FILE_SIZE') {
            error = apiError('Image must be 5 MB or smaller.', 413);
        } else if (error instanceof multer.MulterError) {
            error = apiError('Only one image can be uploaded at a time.', 400);
        } else if (!error.statusCode) {
            error = apiError('The server could not complete the request.');
        }

        if (error.statusCode >= 500) {
            console.error('API request failed:', {
                method: req.method,
                path: req.path,
                message: error.message
            });
        }
        if (res.headersSent) return next(error);
        res.status(error.statusCode).json({ error: error.message });
    });

    return app;
}

const app = createApiApp();

module.exports = {
    app,
    createApiApp,
    validators: { validOrder, validOrderItems, validOrderId },
    helpers: { itemsHash, orderStatuses }
};
