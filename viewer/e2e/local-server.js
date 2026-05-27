// Local server for Playwright e2e tests. Serves viewer/index.html and routes
// /api/viewer-token through viewer/api/viewer-token.js — same code path Vercel
// runs in production, so tests catch drift between the deployed handler and
// any helpers it depends on. Listens on PORT (env), defaults to 4173.

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { config as loadEnv } from 'dotenv';

const __dirname = dirname(fileURLToPath(import.meta.url));
const VIEWER_INDEX = resolve(__dirname, '..', 'index.html');

// Playwright's webServer spawns this process separately from the test runner,
// so globalSetup's `process.env` doesn't reach us. Re-load .env here.
loadEnv({ path: resolve(__dirname, '..', '..', '.env') });

// Import lazily AFTER env is loaded so REQUIRED_ENV-check in viewer-token.js
// sees the real values on first request rather than at module-eval time.
const { default: tokenHandler } = await import('../api/viewer-token.js');

// Vercel's @vercel/node request type adds .query (parsed search params) and
// the response gains .status()/.json()/.setHeader chainable helpers. Node's
// raw http req/res don't, so adapt at the boundary. NOT emulated: req.body
// JSON parsing, req.cookies, res.send, res.redirect — if viewer-token.js ever
// needs one of those, extend here.
function adapt(req, res, url) {
    req.query = Object.fromEntries(url.searchParams);
    res.status = (code) => { res.statusCode = code; return res; };
    res.json = (body) => {
        res.setHeader('Content-Type', 'application/json');
        res.end(JSON.stringify(body));
        return res;
    };
}

const server = createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname === '/api/viewer-token') {
        adapt(req, res, url);
        try {
            await tokenHandler(req, res);
        } catch (err) {
            console.error('token handler threw:', err);
            res.statusCode = 500;
            res.end(JSON.stringify({ error: 'handler_threw', message: err.message }));
        }
        return;
    }
    if (url.pathname === '/' || url.pathname === '/index.html') {
        const html = await readFile(VIEWER_INDEX, 'utf8');
        res.setHeader('Content-Type', 'text/html');
        res.end(html);
        return;
    }
    res.statusCode = 404;
    res.end('not found');
});

const port = Number(process.env.PORT) || 4173;
server.listen(port, () => {
    console.log(`[local-server] listening on http://localhost:${port}`);
});
