// node --test proxy/test.mjs
// Runs the real proxy process against a fake upstream.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const PROXY_PORT = 18897;
const UPSTREAM_PORT = 18898;
const logFile = path.join(os.tmpdir(), `gpt-retry-proxy-test-${process.pid}.log`);

// scenario name -> list of responses, one per attempt (last one repeats)
const scenarios = new Map();
const seen = [];

const sse = (...events) => events.map(([type, data]) => `event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`).join('');
const OK_STREAM = sse(
    ['response.created', { response: { id: 'r1' } }],
    ['response.output_text.delta', { delta: 'hello' }],
    ['response.completed', { response: { id: 'r1' } }],
);
const OVERLOADED_EVENT = ['error', { error: { type: 'service_unavailable_error', code: 'server_is_overloaded', message: 'Our servers are currently overloaded.' } }];

let upstream;
let proxy;

before(async () => {
    upstream = http.createServer((req, res) => {
        const chunks = [];
        req.on('data', (c) => chunks.push(c));
        req.on('end', () => {
            const name = req.headers['x-scenario'] || 'ok';
            seen.push({ name, url: req.url, host: req.headers.host, auth: req.headers.authorization, body: Buffer.concat(chunks).toString(), encoding: req.headers['accept-encoding'] });
            const list = scenarios.get(name) || [{ status: 200, body: OK_STREAM }];
            const attempt = seen.filter((s) => s.name === name).length;
            const reply = list[Math.min(attempt, list.length) - 1];
            if (reply.hang) return;
            res.writeHead(reply.status, reply.headers || {});
            if (reply.chunks) {
                let i = 0;
                const next = () => { if (i < reply.chunks.length) { res.write(reply.chunks[i++]); setTimeout(next, 20); } else res.end(); };
                return next();
            }
            res.end(reply.body ?? '');
        });
    });
    await new Promise((r) => upstream.listen(UPSTREAM_PORT, '127.0.0.1', r));

    proxy = spawn(process.execPath, [path.join(here, 'codex-gpt-retry-proxy.mjs')], {
        env: {
            ...process.env,
            GPT_RETRY_PORT: String(PROXY_PORT),
            GPT_RETRY_UPSTREAM: `http://127.0.0.1:${UPSTREAM_PORT}`,
            GPT_RETRY_UPSTREAM_PROXY: '',
            GPT_RETRY_MAX_WAIT_SECONDS: '2',
            GPT_RETRY_BACKOFF_MIN_MS: '50',
            GPT_RETRY_LOG: logFile,
        },
        stdio: 'inherit',
    });
    for (let i = 0; i < 50; i++) {
        try { await request('GET', '/__health'); return; } catch { await new Promise((r) => setTimeout(r, 100)); }
    }
    throw new Error('proxy did not start');
});

after(() => {
    proxy?.kill();
    upstream?.close();
    fs.rmSync(logFile, { force: true });
});

function request(method, url, { scenario, body = '', headers = {} } = {}) {
    return new Promise((resolve, reject) => {
        const req = http.request({ host: '127.0.0.1', port: PROXY_PORT, method, path: url, headers: { ...(scenario ? { 'x-scenario': scenario } : {}), ...headers } }, (res) => {
            const chunks = [];
            res.on('data', (c) => chunks.push(c));
            res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString() }));
        });
        req.on('error', reject);
        req.end(body);
    });
}

const attempts = (name) => seen.filter((s) => s.name === name).length;
const responses = '/backend-api/codex/responses';

test('forwards path, query, body and auth; rewrites host; forces identity encoding', async () => {
    const res = await request('POST', `${responses}?x=1`, { scenario: 'ok', body: '{"input":"中文"}', headers: { authorization: 'Bearer abc', 'accept-encoding': 'gzip' } });
    assert.equal(res.status, 200);
    assert.equal(res.body, OK_STREAM);
    const s = seen.find((x) => x.name === 'ok');
    assert.equal(s.url, `${responses}?x=1`);
    assert.equal(s.host, `127.0.0.1:${UPSTREAM_PORT}`);
    assert.equal(s.auth, 'Bearer abc');
    assert.equal(s.body, '{"input":"中文"}');
    assert.equal(s.encoding, 'identity');
});

test('retries 503 until the stream succeeds', async () => {
    scenarios.set('503', [{ status: 503, body: '{"error":{"message":"overloaded"}}' }, { status: 503, body: 'Service Unavailable' }, { status: 200, body: OK_STREAM }]);
    const res = await request('POST', responses, { scenario: '503' });
    assert.equal(res.status, 200);
    assert.equal(res.body, OK_STREAM);
    assert.equal(attempts('503'), 3);
});

test('retries an SSE overloaded error that arrives before any output', async () => {
    scenarios.set('sse-early', [
        { status: 200, chunks: [sse(['response.created', { response: { id: 'x' } }]), sse(OVERLOADED_EVENT)] },
        { status: 200, body: OK_STREAM },
    ]);
    const res = await request('POST', responses, { scenario: 'sse-early' });
    assert.equal(res.status, 200);
    assert.equal(res.body, OK_STREAM, 'client sees only the healthy attempt');
    assert.equal(attempts('sse-early'), 2);
});

test('does not retry once output has been forwarded', async () => {
    const stream = sse(['response.created', {}], ['response.output_text.delta', { delta: 'partial' }], OVERLOADED_EVENT);
    scenarios.set('sse-late', [{ status: 200, chunks: [stream] }]);
    const res = await request('POST', responses, { scenario: 'sse-late' });
    assert.equal(res.body, stream);
    assert.equal(attempts('sse-late'), 1);
});

test('model text mentioning overload is not treated as an error', async () => {
    const stream = sse(['response.created', {}], ['response.output_text.delta', { delta: 'server_is_overloaded 503 at capacity' }], ['response.completed', {}]);
    scenarios.set('text', [{ status: 200, body: stream }]);
    const res = await request('POST', responses, { scenario: 'text' });
    assert.equal(res.body, stream);
    assert.equal(attempts('text'), 1);
});

test('usage limit 429 passes through untouched', async () => {
    const body = '{"error":{"type":"usage_limit_reached","message":"You have hit your usage limit."}}';
    scenarios.set('quota', [{ status: 429, body, headers: { 'x-codex-primary-used-percent': '100' } }]);
    const res = await request('POST', responses, { scenario: 'quota' });
    assert.equal(res.status, 429);
    assert.equal(res.body, body);
    assert.equal(res.headers['x-codex-primary-used-percent'], '100');
    assert.equal(attempts('quota'), 1);
});

test('generic 429 is retried', async () => {
    scenarios.set('rate', [{ status: 429, body: 'Too Many Requests', headers: { 'retry-after': '0' } }, { status: 200, body: OK_STREAM }]);
    const res = await request('POST', responses, { scenario: 'rate' });
    assert.equal(res.status, 200);
    assert.equal(attempts('rate'), 2);
});

test('other client errors pass through', async () => {
    scenarios.set('bad', [{ status: 400, body: '{"error":"bad"}' }]);
    const res = await request('POST', responses, { scenario: 'bad' });
    assert.equal(res.status, 400);
    assert.equal(res.body, '{"error":"bad"}');
    assert.equal(attempts('bad'), 1);
});

test('gives up after the retry window and shows the real error', async () => {
    scenarios.set('down', [{ status: 503, body: 'still overloaded' }]);
    const started = Date.now();
    const res = await request('POST', responses, { scenario: 'down' });
    assert.equal(res.status, 503);
    assert.equal(res.body, 'still overloaded');
    assert.ok(Date.now() - started < 4000);
    assert.ok(attempts('down') > 2);
});

test('early SSE error after the window is forwarded as-is', async () => {
    const stream = sse(['response.created', {}], OVERLOADED_EVENT);
    scenarios.set('sse-down', [{ status: 200, chunks: [stream] }]);
    const res = await request('POST', responses, { scenario: 'sse-down' });
    assert.equal(res.status, 200);
    assert.equal(res.body, stream);
});

test('non-model GET passes through with query', async () => {
    scenarios.set('models', [{ status: 200, body: '{"models":[]}', headers: { 'content-type': 'application/json' } }]);
    const res = await request('GET', '/backend-api/codex/models?client_version=1', { scenario: 'models' });
    assert.equal(res.status, 200);
    assert.equal(res.body, '{"models":[]}');
    assert.equal(seen.find((s) => s.name === 'models').url, '/backend-api/codex/models?client_version=1');
});

test('websocket upgrade gets 426 so Codex falls back to HTTPS', async () => {
    const reply = await new Promise((resolve, reject) => {
        const socket = net.connect(PROXY_PORT, '127.0.0.1', () => {
            socket.write(`GET ${responses} HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n`);
        });
        let data = '';
        socket.on('data', (d) => { data += d; });
        socket.on('end', () => resolve(data));
        socket.on('error', reject);
    });
    assert.match(reply, /^HTTP\/1\.1 426/);
});

test('client disconnect stops the retry loop', async () => {
    scenarios.set('abort', [{ status: 503, body: 'x' }]);
    await new Promise((resolve) => {
        const req = http.request({ host: '127.0.0.1', port: PROXY_PORT, method: 'POST', path: responses, headers: { 'x-scenario': 'abort' } });
        req.on('error', () => resolve());
        req.end();
        setTimeout(() => { req.destroy(); resolve(); }, 150);
    });
    const count = attempts('abort');
    await new Promise((r) => setTimeout(r, 1500));
    assert.equal(attempts('abort'), count, 'no further upstream attempts after the client left');
});

test('health endpoint reports counters and the log records retries', async () => {
    const res = await request('GET', '/__health');
    const health = JSON.parse(res.body);
    assert.equal(health.ok, true);
    assert.ok(health.retries >= 4);
    assert.ok(health.recovered >= 3);
    const log = fs.readFileSync(logFile, 'utf8');
    assert.match(log, /"event":"retry"/);
    assert.match(log, /"event":"recovered"/);
    assert.match(log, /"event":"late_error_passed"/);
});
