const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');

function createLocalJsonFile(filePath, { initialValue, validate }) {
    let writeQueue = Promise.resolve();

    async function readFromDisk() {
        try {
            const contents = await fs.readFile(filePath, 'utf8');
            return validate(JSON.parse(contents));
        } catch (error) {
            if (error.code === 'ENOENT') return structuredClone(initialValue);
            throw error;
        }
    }

    function read() {
        return writeQueue.then(readFromDisk);
    }

    function update(mutator) {
        const operation = writeQueue.then(async () => {
            const current = await readFromDisk();
            const next = structuredClone(current);
            const result = await mutator(next);
            const temporaryPath = `${filePath}.${process.pid}.${crypto.randomUUID()}.tmp`;

            try {
                await fs.mkdir(path.dirname(filePath), { recursive: true });
                await fs.writeFile(temporaryPath, JSON.stringify(next, null, 2), {
                    encoding: 'utf8',
                    flag: 'wx',
                    mode: 0o600
                });
                await fs.rename(temporaryPath, filePath);
            } catch (error) {
                await fs.unlink(temporaryPath).catch(unlinkError => {
                    if (unlinkError.code !== 'ENOENT') throw unlinkError;
                });
                throw error;
            }

            return result;
        });

        writeQueue = operation.then(() => undefined, () => undefined);
        return operation;
    }

    return { read, update };
}

function validateStore(store) {
    if (
        !store ||
        typeof store !== 'object' ||
        Array.isArray(store) ||
        !Array.isArray(store.menu) ||
        !Array.isArray(store.posters) ||
        !Array.isArray(store.orders)
    ) {
        throw new Error('Local restaurant data file has an invalid structure.');
    }

    return store;
}

function createLocalStore(storePath) {
    return createLocalJsonFile(storePath, {
        initialValue: { menu: [], posters: [], orders: [] },
        validate: validateStore
    });
}

function createLocalAccountsStore(filePath) {
    return createLocalJsonFile(filePath, {
        initialValue: [],
        validate(accounts) {
            if (!Array.isArray(accounts) || accounts.some(account =>
                !account ||
                typeof account !== 'object' ||
                typeof account.id !== 'string' ||
                typeof account.email !== 'string' ||
                typeof account.phone !== 'string' ||
                typeof account.name !== 'string' ||
                typeof account.passwordSalt !== 'string' ||
                typeof account.passwordHash !== 'string'
            )) {
                throw new Error('Local customer accounts file has an invalid structure.');
            }
            return accounts;
        }
    });
}

module.exports = { createLocalAccountsStore, createLocalStore };
