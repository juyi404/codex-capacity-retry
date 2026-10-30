#!/usr/bin/env node
// Local retry proxy for Codex's official ChatGPT channel.
//
// Codex (Desktop and CLI) is pointed here with
//   openai_base_url = "http://127.0.0.1:18798/backend-api/codex"
// and every request is forwarded to https://chatgpt.com. When the backend
// answers with a capacity-style failure *before* any model output has been
// forwarded, the request is re-sent in the background, so Codex never sees
// "Selected model is at capacity". Failures after output started, quota /
// usage-limit errors and all other errors pass through unchanged.
//
// No dependencies; Node 18+.

import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import os from 'node:os';
import path from 'node:path';
import tls from 'node:tls';

const PORT = Number(process.env.GPT_RETRY_PORT || 18798);
const UPSTREAM = new URL(process.env.GPT_RETRY_UPSTREAM || 'https://chatgpt.com');
const UPSTREAM_PROXY = process.env.GPT_RETRY_UPSTREAM_PROXY ?? process.env.HTTPS_PROXY ?? process.env.https_proxy ?? '';
// Retry window for model requests; other requests get a short one.
const MAX_WAIT_MS = Number(process.env.GPT_RETRY_MAX_WAIT_SECONDS || 600) * 1000;
const OTHER_MAX_WAIT_MS = 20_000;
const BACKOFF_MIN_MS = Number(process.env.GPT_RETRY_BACKOFF_MIN_MS || 1000);
const BACKOFF_MAX_MS = 15_000;
const LOG_FILE = process.env.GPT_RETRY_LOG || path.join(os.homedir(), '.codex', 'gpt-retry-proxy.log');
const LOG_MAX_BYTES = 5 * 1024 * 1024;

// Matched only against upstream error bodies and SSE error events, never
// against model output.
const CAPACITY_RE = /server_is_overloaded|service_unavailable|overloaded|at capacity|try a different model|temporarily unavailable|too many requests|slow_down/i;
const QUOTA_RE = /usage[_ ]limit|insufficient[_ ]quota|exceeded your current quota|quota exceeded|payment required|purchase more credits/i;
const RETRY_STATUS = new Set([429, 500, 502, 503, 504, 520, 521, 522, 523, 524, 529]);
// SSE events that carry no model output; they are held back until the
// stream proves healthy so an early error can still be retried invisibly.
const PRELUDE_EVENTS = new Set(['response.created', 'response.in_progress', 'response.queued', 'codex.rate_limits', 'keepalive']);
const HOP_BY_HOP = new Set(['host', 'connection', 'keep-alive', 'proxy-connection', 'proxy-authorization', 'transfer-encoding', 'upgrade', 'te', 'trailer', 'content-length', 'accept-encoding']);

const stats = { started: new Date().toISOString(), requests: 0, retries: 0, recovered: 0, gaveUp: 0, lateErrors: 0 };
let nextId = 1;

function log(event, fields = {}) {
    const line = JSON.stringify({ ts: new Date().toISOString(), event, ...fields }) + '\n';
    try {
        if (fs.existsSync(LOG_FILE) && fs.statSync(LOG_FILE).size > LOG_MAX_BYTES) {
            fs.renameSync(LOG_FILE, LOG_FILE + '.1');
        }
        fs.appendFileSync(LOG_FILE, line);
    } catch {}
}

const sleep = (ms, signal) => new Promise((resolve) => {
    const timer = setTimeout(resolve, ms);
    signal?.addEventListener('abort', () => { clearTimeout(timer); resolve(); }, { once: true });
});

function backoff(attempt, retryAfterHeader) {
    const retryAfter = Number(retryAfterHeader);
    if (Number.isFinite(retryAfter) && retryAfter > 0) return Math.min(retryAfter * 1000, 60_000);
    return Math.min(BACKOFF_MIN_MS * 2 ** (attempt - 1), BACKOFF_MAX_MS);
}

function isRetryableError(text) {
    return CAPACITY_RE.test(text) && !QUOTA_RE.test(text);
}

// Opens a CONNECT tunnel through the local HTTP proxy (mihomo), because
// chatgpt.com is not reachable directly from this machine.
function openTunnel(host, port) {
    return new Promise((resolve, reject) => {
        const proxy = new URL(UPSTREAM_PROXY);
        const req = http.request({
            host: proxy.hostname,
            port: proxy.port || 80,
            method: 'CONNECT',
            path: `${host}:${port}`,
            headers: { host: `${host}:${port}` },
        });
        req.once('connect', (res, socket) => {
            if (res.statusCode === 200) resolve(socket);
            else { socket.destroy(); reject(new Error(`proxy CONNECT failed: ${res.statusCode}`)); }
        });
        req.once('error', reject);
        req.end();
    });
}

async function sendUpstream(req, body, signal) {
    const headers = {};
    for (const [name, value] of Object.entries(req.headers)) {
        if (!HOP_BY_HOP.has(name)) headers[name] = value;
    }
    headers.host = UPSTREAM.host;
    headers['accept-encoding'] = 'identity';
    if (body.length > 0 || req.method === 'POST') headers['content-length'] = String(body.length);

    const secure = UPSTREAM.protocol === 'https:';
    const port = Number(UPSTREAM.port || (secure ? 443 : 80));
    const options = {
        method: req.method,
        host: UPSTREAM.hostname,
        port,
        path: req.url,
        headers,
        signal,
    };
    if (secure && UPSTREAM_PROXY) {
        const socket = await openTunnel(UPSTREAM.hostname, port);
        const tlsSocket = tls.connect({ socket, servername: UPSTREAM.hostname, ALPNProtocols: ['http/1.1'] });
        // A one-shot agent: with agent:false Node ignores createConnection.
        const agent = new https.Agent({ keepAlive: false });
        agent.createConnection = () => tlsSocket;
        options.agent = agent;
    }
    const transport = secure ? https : http;
    return new Promise((resolve, reject) => {
        const upstreamReq = transport.request(options, (upstream) => {
            // Errors after an abort or a retry decision are expected; the
            // pipe/guard code installs its own handlers where it matters.
            upstream.on('error', () => {});
            resolve(upstream);
        });
        upstreamReq.on('error', reject);
        upstreamReq.end(body);
    });
}

function readAll(stream, limit = 1024 * 1024) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        let size = 0;
        stream.on('data', (chunk) => { size += chunk.length; if (size <= limit) chunks.push(chunk); });
        stream.once('end', () => resolve(Buffer.concat(chunks)));
        stream.once('error', reject);
    });
}

function responseHeaders(upstream) {
    const headers = {};
    for (const [name, value] of Object.entries(upstream.headers)) {
        if (!HOP_BY_HOP.has(name)) headers[name] = value;
    }
    return headers;
}

// Reads SSE events until the first one that carries output. Resolves with
//   { verdict: 'stream', buffered }        healthy: forward buffered + rest
//   { verdict: 'retry', buffered, text }   capacity error before any output
//   { verdict: 'end', buffered }           stream ended inside the prelude
function guardStream(upstream) {
    return new Promise((resolve, reject) => {
        let pending = '';
        const buffered = [];
        const finish = (result) => {
            upstream.off('data', onData);
            upstream.off('end', onEnd);
            upstream.off('error', onError);
            resolve(result);
        };
        const onData = (chunk) => {
            buffered.push(chunk);
            pending += chunk.toString('utf8');
            let boundary;
            while ((boundary = pending.search(/\r?\n\r?\n/)) !== -1) {
                const block = pending.slice(0, boundary);
                pending = pending.slice(boundary).replace(/^\r?\n\r?\n/, '');
                if (!block.trim() || block.split(/\r?\n/).every((l) => l.startsWith(':'))) continue;
                let type = '';
                const data = [];
                for (const line of block.split(/\r?\n/)) {
                    if (line.startsWith('event:')) type = line.slice(6).trim();
                    else if (line.startsWith('data:')) data.push(line.slice(5).trim());
                }
                const dataText = data.join('\n');
                if (!type) {
                    try { type = JSON.parse(dataText).type || ''; } catch {}
                }
                if (PRELUDE_EVENTS.has(type)) continue;
                if ((type === 'error' || type === 'response.failed') && isRetryableError(dataText)) {
                    upstream.pause();
                    return finish({ verdict: 'retry', buffered, text: dataText.slice(0, 300) });
                }
                upstream.pause();
                return finish({ verdict: 'stream', buffered });
            }
        };
        const onEnd = () => finish({ verdict: 'end', buffered });
        const onError = (error) => { upstream.off('data', onData); upstream.off('end', onEnd); reject(error); };
        upstream.on('data', onData);
        upstream.once('end', onEnd);
        upstream.once('error', onError);
    });
}

// Watches an already forwarded stream for late capacity errors (logging only).
function watchLateErrors(upstream, id, alreadyForwarded) {
    let tail = '';
    const scan = (text) => {
        tail = (tail + text).slice(-8192);
        if (/"type"\s*:\s*"(?:error|response\.failed)"/.test(tail) && isRetryableError(tail)) {
            stats.lateErrors++;
            log('late_error_passed', { id, text: tail.match(/(?:server_is_overloaded|overloaded|at capacity)[^"]{0,80}/i)?.[0] });
            tail = '';
        }
    };
    scan(alreadyForwarded);
    upstream.on('data', (chunk) => scan(chunk.toString('utf8')));
}

async function handle(req, res) {
    if (req.url === '/__health') {
        res.writeHead(200, { 'content-type': 'application/json' });
        return res.end(JSON.stringify({ ok: true, upstream: UPSTREAM.origin, ...stats }));
    }

    const id = nextId++;
    stats.requests++;
    const body = await readAll(req, 512 * 1024 * 1024);
    const pathname = new URL(req.url, 'http://local').pathname;
    const isModelRequest = req.method === 'POST' && /\/responses\/?$/.test(pathname);
    const deadline = Date.now() + (isModelRequest ? MAX_WAIT_MS : OTHER_MAX_WAIT_MS);

    const abort = new AbortController();
    res.once('close', () => { if (!res.writableFinished) abort.abort(); });

    let attempt = 0;
    let lastReason = '';
    for (;;) {
        attempt++;
        let upstream;
        try {
            upstream = await sendUpstream(req, body, abort.signal);
        } catch (error) {
            if (abort.signal.aborted) return;
            lastReason = `connect: ${error.message}`;
            if (Date.now() + backoff(attempt) >= deadline) {
                stats.gaveUp++;
                log('gave_up', { id, path: pathname, attempt, reason: lastReason });
                res.writeHead(502, { 'content-type': 'application/json' });
                return res.end(JSON.stringify({ error: { message: `gpt-retry-proxy: upstream unreachable (${error.message})`, type: 'proxy_error' } }));
            }
            await retryWait(id, pathname, attempt, lastReason, undefined, abort.signal);
            continue;
        }

        const status = upstream.statusCode;
        const isStream = status === 200 && (isModelRequest || /event-stream/i.test(upstream.headers['content-type'] || ''));
        const lastChance = () => Date.now() + backoff(attempt, upstream.headers['retry-after']) >= deadline;

        if (RETRY_STATUS.has(status)) {
            const errorBody = await readAll(upstream).catch(() => Buffer.alloc(0));
            const text = errorBody.toString('utf8');
            // 5xx and generic 429s are transient; plan usage limits are not.
            const retryable = !QUOTA_RE.test(text);
            if (retryable && !lastChance()) {
                lastReason = `${status} ${text.slice(0, 200)}`;
                await retryWait(id, pathname, attempt, lastReason, upstream.headers['retry-after'], abort.signal);
                if (abort.signal.aborted) return;
                continue;
            }
            if (retryable) { stats.gaveUp++; log('gave_up', { id, path: pathname, attempt, reason: `${status} ${text.slice(0, 200)}` }); }
            res.writeHead(status, responseHeaders(upstream));
            return res.end(errorBody);
        }

        if (isStream) {
            let result;
            try {
                result = await guardStream(upstream);
            } catch (error) {
                if (abort.signal.aborted) return;
                lastReason = `stream: ${error.message}`;
                if (lastChance()) { res.destroy(); return; }
                await retryWait(id, pathname, attempt, lastReason, undefined, abort.signal);
                continue;
            }
            if (result.verdict === 'retry' && !lastChance()) {
                upstream.destroy();
                lastReason = `sse ${result.text}`;
                await retryWait(id, pathname, attempt, lastReason, undefined, abort.signal);
                if (abort.signal.aborted) return;
                continue;
            }
            if (result.verdict === 'retry') {
                stats.gaveUp++;
                log('gave_up', { id, path: pathname, attempt, reason: `sse ${result.text}` });
            } else if (attempt > 1) {
                stats.recovered++;
                log('recovered', { id, path: pathname, attempt });
            }
            res.writeHead(status, responseHeaders(upstream));
            for (const chunk of result.buffered) res.write(chunk);
            if (result.verdict === 'end') return res.end();
            watchLateErrors(upstream, id, Buffer.concat(result.buffered).toString('utf8'));
            upstream.pipe(res);
            upstream.once('error', () => res.destroy());
            upstream.resume();
            return;
        }

        if (attempt > 1) { stats.recovered++; log('recovered', { id, path: pathname, attempt }); }
        res.writeHead(status, responseHeaders(upstream));
        upstream.pipe(res);
        upstream.once('error', () => res.destroy());
        return;
    }
}

async function retryWait(id, pathname, attempt, reason, retryAfter, signal) {
    const wait = backoff(attempt, retryAfter);
    stats.retries++;
    log('retry', { id, path: pathname, attempt, wait_ms: wait, reason: reason.slice(0, 300) });
    await sleep(wait, signal);
}

const server = http.createServer((req, res) => {
    handle(req, res).catch((error) => {
        log('handler_error', { message: error.message });
        if (!res.headersSent) { res.writeHead(502); res.end(); } else res.destroy();
    });
});

// Codex prefers a Responses WebSocket. 426 makes it fall back to HTTPS at
// once (and silently), which is the path this proxy can retry.
server.on('upgrade', (req, socket) => {
    socket.end('HTTP/1.1 426 Upgrade Required\r\ncontent-length: 0\r\nconnection: close\r\n\r\n');
});

server.requestTimeout = 0;
server.headersTimeout = 60_000;
server.keepAliveTimeout = 30_000;

server.once('error', (error) => {
    // Another instance already owns the port: the scheduled task fires
    // regularly, so exiting here keeps exactly one proxy running.
    if (error.code === 'EADDRINUSE') process.exit(0);
    log('server_error', { message: error.message });
    process.exit(1);
});

process.on('uncaughtException', (error) => log('uncaught', { message: error.message, stack: error.stack?.split('\n').slice(0, 4).join(' | ') }));
process.on('unhandledRejection', (error) => log('unhandled_rejection', { message: String(error?.message || error) }));

server.listen(PORT, '127.0.0.1', () => {
    log('started', { port: PORT, upstream: UPSTREAM.origin, upstream_proxy: UPSTREAM_PROXY || 'direct', pid: process.pid });
});
