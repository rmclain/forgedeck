'use strict';

// ForgeDeck companion: a read-only, default-deny HTTP API (GET only).
// Works as a plain `http` request listener and as Express-style (req, res, next) middleware.

const fs = require('node:fs');
const sec = require('./security');

const SCHEMA_VERSION = '1.0';
const IMPLEMENTATION = { name: 'forgedeck-companion-node', version: '1.0.0' };
const DEFAULT_BASE_PATH = '/_forgedeck/v1';
const WINDOWS = Object.freeze({ '24h': 86400, '7d': 604800, '30d': 2592000, '90d': 7776000 });
const MAX_RANGE_SECONDS = WINDOWS['90d'];
const ENVIRONMENTS = Object.freeze(['production', 'staging', 'development', 'preview', 'test']);
const CAPABILITIES = Object.freeze(['status', 'metrics', 'leads', 'events']);
const LEAD_KINDS = Object.freeze(['lead', 'signup', 'paid_conversion', 'renewal', 'cancellation']);
const EVENT_KINDS = Object.freeze([...LEAD_KINDS, 'deploy', 'incident']);
const HEALTH_STATES = Object.freeze(['healthy', 'degraded', 'unhealthy']);
const DEFAULT_LIMIT = 50;
const MAX_LIMIT = 100;
const DEFAULT_METRICS = Object.freeze(['leads', 'signups', 'paid_conversions', 'renewals', 'cancellations']);
const DEFAULT_TITLES = Object.freeze({
  lead: 'New lead',
  signup: 'New signup',
  paid_conversion: 'Paid conversion',
  renewal: 'Renewal',
  cancellation: 'Cancellation',
  deploy: 'Deploy',
  incident: 'Incident',
});

// capability: null => available to any authenticated token holding the scope.
const ROUTES = Object.freeze({
  manifest: { scope: 'status:read', capability: null },
  status: { scope: 'status:read', capability: 'status' },
  metrics: { scope: 'metrics:read', capability: 'metrics' },
  leads: { scope: 'leads:read', capability: 'leads' },
  events: { scope: 'events:read', capability: 'events' },
});

const ID_RE = /^[a-z0-9][a-z0-9._-]{0,62}$/;
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$/;
const SHA_RE = /^[0-9a-f]{7,40}$/i;

class HttpError extends Error {
  constructor(status, code, message, headers) {
    super(message);
    this.status = status;
    this.code = code;
    this.headers = headers || {};
  }
}

function isoSeconds(ms) {
  return new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function toIsoOrNull(value) {
  if (value == null) return null;
  const ms = value instanceof Date ? value.getTime() : typeof value === 'number' ? value : Date.parse(String(value));
  return Number.isFinite(ms) ? isoSeconds(ms) : null;
}

function shortString(value, max) {
  if (typeof value !== 'string' && typeof value !== 'number') return null;
  // eslint-disable-next-line no-control-regex
  const s = String(value).replace(/[\u0000-\u001f\u007f]/g, ' ').trim();
  return s.length === 0 ? null : s.slice(0, max);
}

function normalizeRelease(raw) {
  const r = raw && typeof raw === 'object' ? raw : {};
  const out = {
    commit_sha: typeof r.commit_sha === 'string' && SHA_RE.test(r.commit_sha) ? r.commit_sha.toLowerCase() : null,
    version: shortString(r.version, 64),
    deployed_at: toIsoOrNull(r.deployed_at),
  };
  const buildId = shortString(r.build_id, 128);
  if (buildId) out.build_id = buildId;
  const builtAt = toIsoOrNull(r.built_at);
  if (builtAt) out.built_at = builtAt;
  if (!out.deployed_at && builtAt) out.deployed_at = builtAt;
  return out;
}

/**
 * Read a CI-generated release fingerprint (see contract/deployment-fingerprint.md).
 * Returns a normalised release object, or null if the file is missing/invalid.
 */
function loadReleaseFile(filePath) {
  try {
    const parsed = JSON.parse(fs.readFileSync(filePath, 'utf8'));
    if (!parsed || typeof parsed !== 'object') return null;
    return normalizeRelease(parsed);
  } catch {
    return null;
  }
}

function worstState(states) {
  let worst = 0;
  for (const s of states) worst = Math.max(worst, HEALTH_STATES.indexOf(s));
  return HEALTH_STATES[worst];
}

function normalizeHealth(raw) {
  const checks = [];
  if (raw && Array.isArray(raw.checks)) {
    for (const c of raw.checks.slice(0, 50)) {
      if (!c || typeof c.id !== 'string' || !/^[a-z0-9][a-z0-9._-]{0,62}$/i.test(c.id)) continue;
      // Only id + state are exposed: no error messages, hostnames or connection strings.
      checks.push({ id: c.id, state: HEALTH_STATES.includes(c.state) ? c.state : 'unhealthy' });
    }
  }
  const states = checks.map((c) => c.state);
  if (raw && HEALTH_STATES.includes(raw.state)) states.push(raw.state);
  return { state: states.length ? worstState(states) : 'healthy', checks };
}

function sanitizeMetrics(raw, allowed) {
  const out = {};
  if (!raw || typeof raw !== 'object') return out;
  for (const key of allowed) {
    const v = raw[key];
    if (typeof v === 'number' && Number.isFinite(v)) out[key] = v;
  }
  return out;
}

/** Whitelist the fields of a lead/event item. Anything not listed here is never emitted. */
function sanitizeItem(raw, kinds, maskedLabel) {
  if (!raw || typeof raw !== 'object') return null;
  if (typeof raw.id !== 'string' || !/^[A-Za-z0-9_.:-]{1,128}$/.test(raw.id)) return null;
  if (!kinds.includes(raw.kind)) return null;
  const tMs = raw.occurred_at instanceof Date ? raw.occurred_at.getTime() : Date.parse(String(raw.occurred_at));
  if (!Number.isFinite(tMs)) return null;
  const source = typeof raw.source === 'string' && /^[A-Za-z0-9_.-]{1,64}$/.test(raw.source) ? raw.source : 'unknown';
  const item = {
    id: raw.id,
    kind: raw.kind,
    occurred_at: isoSeconds(tMs),
    source,
    title: shortString(raw.title, 120) || DEFAULT_TITLES[raw.kind],
    value_cents: Number.isInteger(raw.value_cents) ? raw.value_cents : null,
  };
  if (maskedLabel) {
    const label = sec.maskEmail(raw.email);
    if (label) item.label = label;
  }
  return { item, tMs: Math.floor(tMs / 1000) * 1000 };
}

function validateConfig(config) {
  if (!config || typeof config !== 'object') throw new TypeError('createCompanion(config): config is required');
  if (typeof config.productId !== 'string' || !ID_RE.test(config.productId)) {
    throw new TypeError('config.productId must match ' + ID_RE);
  }
  if (!ENVIRONMENTS.includes(config.environment)) {
    throw new TypeError('config.environment must be one of: ' + ENVIRONMENTS.join(', '));
  }
  const componentId = config.componentId || 'backend';
  if (!ID_RE.test(componentId)) throw new TypeError('config.componentId is invalid');
  const componentIds = Array.isArray(config.componentIds) && config.componentIds.length ? config.componentIds.map(String) : [componentId];
  for (const c of componentIds) if (!ID_RE.test(c)) throw new TypeError(`config.componentIds contains invalid id "${c}"`);

  const caps = config.capabilities || {};
  for (const k of Object.keys(caps)) if (!CAPABILITIES.includes(k)) throw new TypeError(`unknown capability "${k}"`);
  // Default deny: a capability is on only when explicitly set to true.
  const enabled = CAPABILITIES.filter((c) => caps[c] === true);

  const metadata = {};
  if (config.metadata && typeof config.metadata === 'object') {
    for (const [k, v] of Object.entries(config.metadata).slice(0, 20)) {
      if (!/^[a-z][a-z0-9_]{0,47}$/.test(k)) continue;
      const s = shortString(v, 200);
      if (s !== null) metadata[k] = s;
    }
  }

  const signing = config.signing || {};
  if (signing.secret != null && (typeof signing.secret !== 'string' || signing.secret.length < 16)) {
    throw new TypeError('config.signing.secret must be a string of at least 16 characters');
  }
  const rl = config.rateLimit || {};
  const metricsCfg = config.metrics || {};
  const allowed = Array.isArray(metricsCfg.allowed) ? metricsCfg.allowed.map(String) : [...DEFAULT_METRICS];
  for (const m of allowed) if (!/^[a-z][a-z0-9_]{0,47}$/.test(m)) throw new TypeError(`invalid metric name "${m}"`);

  return {
    basePath: (config.basePath || DEFAULT_BASE_PATH).replace(/\/+$/, ''),
    productId: config.productId,
    environment: config.environment,
    componentId,
    componentIds,
    metadata,
    enabled,
    tokens: sec.normalizeTokens(config.tokens),
    signingSecret: signing.secret || null,
    requireHttps: config.requireHttps !== false,
    trustProxy: config.trustProxy === true,
    rateLimit: { limit: Number.isInteger(rl.limit) && rl.limit > 0 ? rl.limit : 60, windowSeconds: rl.windowSeconds > 0 ? rl.windowSeconds : 60 },
    maskedLabel: !!(config.leads && config.leads.maskedLabel === true),
    metricsAllowed: allowed,
    metricsSource: shortString(metricsCfg.source, 64) || 'application',
    providers: config.providers || {},
    bootedAtMs: config.bootedAt != null ? new Date(config.bootedAt).getTime() : Date.now(),
    logger: typeof config.logger === 'function' ? config.logger : config.logger === false ? () => {} : (line) => console.log(line),
    now: typeof config.now === 'function' ? config.now : Date.now,
  };
}

/**
 * Create the companion handler.
 *
 *   const companion = createCompanion({ productId, environment, capabilities, tokens, providers });
 *   http.createServer(companion);            // plain http: non-companion paths get a 404
 *   app.use(companion);                      // Express-style: non-companion paths call next()
 */
function createCompanion(config) {
  const cfg = validateConfig(config);
  const limiter = new sec.RateLimiter(cfg.rateLimit);
  const nonces = new sec.NonceCache();

  function header(req, name) {
    const v = req.headers ? req.headers[name] : undefined;
    return Array.isArray(v) ? v[0] : v;
  }

  function isSecure(req) {
    const socket = req.socket || req.connection || {};
    if (cfg.trustProxy) {
      // Opt-in only: the header is trusted because the operator says a proxy they control sets it.
      const xfp = header(req, 'x-forwarded-proto');
      if (typeof xfp === 'string' && xfp.length) return xfp.split(',')[0].trim().toLowerCase() === 'https';
    }
    if (socket.encrypted) return true;
    return sec.isLoopbackAddress(socket.remoteAddress);
  }

  function baseBody(nowMs) {
    // product_id and environment always come from server config, never from the request.
    return { schema_version: SCHEMA_VERSION, product_id: cfg.productId, environment: cfg.environment, observed_at: isoSeconds(nowMs) };
  }

  async function windowMetrics(windowKey) {
    if (typeof cfg.providers.metrics !== 'function') return {};
    const raw = await cfg.providers.metrics(windowKey, WINDOWS[windowKey]);
    return sanitizeMetrics(raw, cfg.metricsAllowed);
  }

  async function routeManifest(ctx, nowMs) {
    return {
      ...baseBody(nowMs),
      component_ids: cfg.componentIds,
      capabilities: cfg.enabled,
      scopes: [...ctx.token.scopes],
      windows: Object.keys(WINDOWS),
      signing_required: cfg.signingSecret !== null,
      metadata: cfg.metadata,
      companion: IMPLEMENTATION,
    };
  }

  async function routeStatus(ctx, nowMs) {
    let release = cfg.providers.release;
    if (typeof release === 'function') release = await release();
    let health;
    try {
      health = normalizeHealth(typeof cfg.providers.health === 'function' ? await cfg.providers.health() : null);
    } catch {
      health = { state: 'unhealthy', checks: [{ id: 'health_provider', state: 'unhealthy' }] };
    }
    const metrics = {};
    if (cfg.enabled.includes('metrics') && sec.hasScope(ctx.token, 'metrics:read')) {
      try {
        for (const [k, v] of Object.entries(await windowMetrics('24h'))) metrics[`${k}_24h`] = v;
      } catch {
        // Status must still be served when the metrics source is down.
      }
    }
    const body = {
      schema_version: SCHEMA_VERSION,
      product_id: cfg.productId,
      component_id: cfg.componentId,
      environment: cfg.environment,
      observed_at: isoSeconds(nowMs),
      release: normalizeRelease(release),
      health,
      metrics,
      capabilities: cfg.enabled,
      booted_at: isoSeconds(cfg.bootedAtMs),
    };
    if (typeof cfg.providers.instances === 'function') {
      const raw = await cfg.providers.instances();
      if (Array.isArray(raw)) {
        const instances = [];
        for (const i of raw.slice(0, 100)) {
          if (!i || typeof i.id !== 'string' || !/^[A-Za-z0-9_.:-]{1,128}$/.test(i.id)) continue;
          instances.push({ id: i.id, commit_sha: typeof i.commit_sha === 'string' && SHA_RE.test(i.commit_sha) ? i.commit_sha.toLowerCase() : null });
        }
        body.instances = instances;
      }
    }
    return body;
  }

  async function routeMetrics(ctx, nowMs, query) {
    const windowKey = query.has('window') ? query.get('window') : '24h';
    if (!Object.prototype.hasOwnProperty.call(WINDOWS, windowKey)) {
      throw new HttpError(400, 'invalid_window', 'window must be one of: ' + Object.keys(WINDOWS).join(', '));
    }
    return { ...baseBody(nowMs), window: windowKey, source: cfg.metricsSource, metrics: await windowMetrics(windowKey) };
  }

  function parseListParams(query, nowMs) {
    let limit = DEFAULT_LIMIT;
    if (query.has('limit')) {
      const rawLimit = query.get('limit');
      if (!/^\d{1,4}$/.test(rawLimit) || Number(rawLimit) < 1 || Number(rawLimit) > MAX_LIMIT) {
        throw new HttpError(400, 'invalid_limit', `limit must be an integer between 1 and ${MAX_LIMIT}`);
      }
      limit = Number(rawLimit);
    }
    let after = null;
    if (query.has('cursor')) {
      after = sec.decodeCursor(query.get('cursor'));
      if (!after) throw new HttpError(400, 'invalid_cursor', 'cursor is not valid');
    }
    const parseTime = (name) => {
      if (!query.has(name)) return null;
      const raw = query.get(name);
      const ms = ISO_RE.test(raw) ? Date.parse(raw) : NaN;
      if (!Number.isFinite(ms)) throw new HttpError(400, 'invalid_time', `${name} must be an ISO-8601 timestamp such as 2026-11-15T16:00:00Z`);
      return ms;
    };
    const untilMs = parseTime('until') ?? nowMs;
    const sinceMs = parseTime('since') ?? untilMs - MAX_RANGE_SECONDS * 1000;
    if (sinceMs >= untilMs) throw new HttpError(400, 'invalid_range', 'since must be earlier than until');
    if (untilMs - sinceMs > MAX_RANGE_SECONDS * 1000) throw new HttpError(400, 'invalid_range', 'time range must not exceed 90 days');
    return { limit, after, sinceMs, untilMs };
  }

  async function routeList(provider, kinds, withLabel, nowMs, query) {
    const { limit, after, sinceMs, untilMs } = parseListParams(query, nowMs);
    let raw = [];
    if (typeof provider === 'function') {
      raw = await provider({
        since: new Date(sinceMs),
        until: new Date(untilMs),
        after: after ? { occurred_at: new Date(after.tMs), id: after.id } : null,
        limit: limit + 1,
      });
    }
    const rows = [];
    for (const r of Array.isArray(raw) ? raw : []) {
      const s = sanitizeItem(r, kinds, withLabel);
      if (!s) continue;
      if (s.tMs < sinceMs - 999 || s.tMs > untilMs) continue;
      if (after && !(s.tMs > after.tMs || (s.tMs === after.tMs && s.item.id > after.id))) continue;
      rows.push(s);
    }
    // Stable order: oldest first, id as tie-breaker. Cursors point at the last item returned.
    rows.sort((a, b) => a.tMs - b.tMs || (a.item.id < b.item.id ? -1 : a.item.id > b.item.id ? 1 : 0));
    const page = rows.slice(0, limit);
    const last = page[page.length - 1];
    return {
      ...baseBody(nowMs),
      items: page.map((p) => p.item),
      next_cursor: rows.length > limit && last ? sec.encodeCursor(last.item.occurred_at, last.item.id) : null,
    };
  }

  async function evaluate(req, ctx, path, query, rawUrl) {
    const nowMs = cfg.now();
    const method = req.method || 'GET';
    if (method !== 'GET') throw new HttpError(405, 'method_not_allowed', 'Only GET is supported', { Allow: 'GET' });
    if (rawUrl.length > 2048) throw new HttpError(400, 'invalid_request', 'Request target too long');
    // Default deny: without at least one configured token nothing is served.
    if (cfg.tokens.length === 0) throw new HttpError(503, 'not_configured', 'Companion is not configured');
    if (cfg.requireHttps && !isSecure(req)) throw new HttpError(403, 'https_required', 'HTTPS is required');

    const remote = (req.socket && req.socket.remoteAddress) || 'unknown';
    const result = sec.verifyToken(sec.extractBearer(header(req, 'authorization')), cfg.tokens, nowMs);
    if (!result.ok) {
      const rl = limiter.hit(`addr:${remote}`, nowMs);
      if (!rl.allowed) throw new HttpError(429, 'rate_limited', 'Too many requests', { 'Retry-After': String(rl.retryAfter) });
      ctx.tokenId = result.id || null;
      throw new HttpError(401, 'unauthorized', 'Missing or invalid bearer token', { 'WWW-Authenticate': 'Bearer' });
    }
    ctx.token = result.record;
    ctx.tokenId = result.record.id;

    const rl = limiter.hit(`token:${result.record.id}`, nowMs);
    if (!rl.allowed) throw new HttpError(429, 'rate_limited', 'Too many requests', { 'Retry-After': String(rl.retryAfter) });

    if (cfg.signingSecret !== null) {
      const timestamp = header(req, 'x-forgedeck-timestamp');
      const signature = header(req, 'x-forgedeck-signature');
      const nowSeconds = Math.floor(nowMs / 1000);
      const v = sec.verifySignature({ secret: cfg.signingSecret, timestamp, signature, method, pathWithQuery: rawUrl, nowSeconds });
      if (!v.ok) throw new HttpError(401, 'invalid_signature', 'Missing, invalid or stale request signature');
      if (!nonces.checkAndStore(`${timestamp}:${signature.toLowerCase()}`, nowSeconds, sec.MAX_SKEW_SECONDS * 2 + 1)) {
        throw new HttpError(401, 'replayed_request', 'Request signature was already used');
      }
    }

    const name = path.slice(cfg.basePath.length + 1);
    const route = Object.prototype.hasOwnProperty.call(ROUTES, name) ? ROUTES[name] : null;
    // Unknown routes and disabled capabilities are indistinguishable.
    if (!route || (route.capability && !cfg.enabled.includes(route.capability))) {
      throw new HttpError(404, 'not_found', 'Not found');
    }
    if (!sec.hasScope(ctx.token, route.scope)) throw new HttpError(403, 'insufficient_scope', `Token lacks scope ${route.scope}`);

    switch (name) {
      case 'manifest':
        return routeManifest(ctx, nowMs);
      case 'status':
        return routeStatus(ctx, nowMs);
      case 'metrics':
        return routeMetrics(ctx, nowMs, query);
      case 'leads':
        return routeList(cfg.providers.leads, LEAD_KINDS, cfg.maskedLabel, nowMs, query);
      default:
        return routeList(cfg.providers.events, EVENT_KINDS, false, nowMs, query);
    }
  }

  function send(res, status, body, headers) {
    const payload = JSON.stringify(body);
    res.statusCode = status;
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.setHeader('Content-Length', Buffer.byteLength(payload));
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    for (const [k, v] of Object.entries(headers || {})) res.setHeader(k, v);
    res.end(payload);
  }

  async function handle(req, res) {
    const started = Date.now();
    const rawUrl = String(req.originalUrl || req.url || '/');
    const qi = rawUrl.indexOf('?');
    const path = qi === -1 ? rawUrl : rawUrl.slice(0, qi);
    const ctx = { token: null, tokenId: null };
    let status = 200;
    try {
      const query = new URLSearchParams(qi === -1 ? '' : rawUrl.slice(qi + 1));
      const body = await evaluate(req, ctx, path, query, rawUrl);
      send(res, 200, body);
    } catch (err) {
      if (err instanceof HttpError) {
        status = err.status;
        send(res, err.status, { schema_version: SCHEMA_VERSION, error: { code: err.code, message: err.message } }, err.headers);
      } else {
        status = 500;
        send(res, 500, { schema_version: SCHEMA_VERSION, error: { code: 'internal_error', message: 'Internal error' } });
      }
    }
    // Log line: method, path WITHOUT query string, status, token id. Never the token or headers.
    const safePath = path.slice(0, 200).replace(/[^\x21-\x7e]/g, '?');
    try {
      cfg.logger(`[forgedeck-companion] ${String(req.method).slice(0, 10)} ${safePath} ${status} token=${ctx.tokenId || '-'} ${Date.now() - started}ms`);
    } catch {
      // A broken logger must not break the response.
    }
    return status;
  }

  function matches(req) {
    const rawUrl = String(req.originalUrl || req.url || '/');
    const qi = rawUrl.indexOf('?');
    const path = qi === -1 ? rawUrl : rawUrl.slice(0, qi);
    return path === cfg.basePath || path.startsWith(cfg.basePath + '/');
  }

  function companion(req, res, next) {
    if (!matches(req)) {
      if (typeof next === 'function') return next();
      send(res, 404, { schema_version: SCHEMA_VERSION, error: { code: 'not_found', message: 'Not found' } });
      return undefined;
    }
    return handle(req, res);
  }

  companion.handle = handle;
  companion.matches = matches;
  companion.basePath = cfg.basePath;
  companion.capabilities = cfg.enabled;
  return companion;
}

module.exports = {
  createCompanion,
  loadReleaseFile,
  normalizeRelease,
  SCHEMA_VERSION,
  WINDOWS,
  ENVIRONMENTS,
  CAPABILITIES,
  LEAD_KINDS,
  EVENT_KINDS,
  HEALTH_STATES,
  MAX_LIMIT,
  DEFAULT_BASE_PATH,
};
