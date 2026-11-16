'use strict';

// Pure security helpers for the ForgeDeck companion. Node built-ins only.

const crypto = require('node:crypto');

const SCOPES = Object.freeze(['status:read', 'metrics:read', 'leads:read', 'events:read']);
const MAX_SKEW_SECONDS = 300;
const HASH_RE = /^[0-9a-f]{64}$/;

function sha256Hex(value) {
  return crypto.createHash('sha256').update(String(value), 'utf8').digest('hex');
}

/** SHA-256 hex digest of a bearer token. Only this digest is kept server-side. */
function hashToken(token) {
  return sha256Hex(token);
}

/** Generate a new random bearer token (256 bits). Show it once, store only hashToken(token). */
function generateToken() {
  return 'fdk_' + crypto.randomBytes(32).toString('base64url');
}

function constantTimeEqualHex(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  if (!HASH_RE.test(a) || !HASH_RE.test(b)) return false;
  return crypto.timingSafeEqual(Buffer.from(a, 'hex'), Buffer.from(b, 'hex'));
}

/**
 * Normalise token records. Accepts `{ id, sha256, scopes, expiresAt, revoked }`
 * or, as a convenience, `{ id, token, ... }` in which case the plaintext is hashed
 * immediately and not retained.
 */
function normalizeTokens(tokens) {
  if (tokens == null) return [];
  if (!Array.isArray(tokens)) throw new TypeError('tokens must be an array');
  const seen = new Set();
  return tokens.map((t, i) => {
    if (!t || typeof t !== 'object') throw new TypeError(`tokens[${i}] must be an object`);
    const id = String(t.id || `token-${i + 1}`);
    if (!/^[A-Za-z0-9_.-]{1,64}$/.test(id)) throw new TypeError(`tokens[${i}].id is invalid`);
    if (seen.has(id)) throw new TypeError(`duplicate token id "${id}"`);
    seen.add(id);
    let sha256;
    if (typeof t.sha256 === 'string') {
      sha256 = t.sha256.toLowerCase();
    } else if (typeof t.token === 'string') {
      if (t.token.length < 16) throw new TypeError(`tokens[${i}].token is too short (min 16 chars)`);
      sha256 = hashToken(t.token);
    } else {
      throw new TypeError(`tokens[${i}] needs "sha256" (preferred) or "token"`);
    }
    if (!HASH_RE.test(sha256)) throw new TypeError(`tokens[${i}].sha256 must be 64 hex chars`);
    const scopes = Array.isArray(t.scopes) ? t.scopes.map(String) : [];
    for (const s of scopes) {
      if (!SCOPES.includes(s)) throw new TypeError(`tokens[${i}] has unknown scope "${s}"`);
    }
    let expiresAtMs = null;
    if (t.expiresAt != null) {
      expiresAtMs = t.expiresAt instanceof Date ? t.expiresAt.getTime() : Date.parse(String(t.expiresAt));
      if (!Number.isFinite(expiresAtMs)) throw new TypeError(`tokens[${i}].expiresAt is not a valid date`);
    }
    return Object.freeze({ id, sha256, scopes: Object.freeze(scopes), expiresAtMs, revoked: t.revoked === true });
  });
}

/** Extract the token from an `Authorization: Bearer <token>` header value, or null. */
function extractBearer(header) {
  if (typeof header !== 'string' || header.length > 600) return null;
  const m = /^Bearer ([A-Za-z0-9._~+/-]{1,512}={0,2})$/.exec(header.trim());
  return m ? m[1] : null;
}

/**
 * Verify a presented token against the stored records.
 * Every record is compared (no early exit) using a constant-time comparison of digests.
 */
function verifyToken(presented, records, nowMs) {
  if (typeof presented !== 'string' || presented.length === 0) return { ok: false, reason: 'missing' };
  const digest = hashToken(presented);
  let match = null;
  for (const rec of records) {
    if (constantTimeEqualHex(digest, rec.sha256) && match === null) match = rec;
  }
  if (!match) return { ok: false, reason: 'unknown' };
  if (match.revoked) return { ok: false, reason: 'revoked', id: match.id };
  if (match.expiresAtMs !== null && nowMs >= match.expiresAtMs) return { ok: false, reason: 'expired', id: match.id };
  return { ok: true, record: match, id: match.id };
}

function hasScope(record, scope) {
  return !!record && Array.isArray(record.scopes) && record.scopes.includes(scope);
}

/** The string that gets signed: "<timestamp>\n<METHOD>\n<path-with-query>". */
function canonicalString(timestamp, method, pathWithQuery) {
  return `${timestamp}\n${String(method).toUpperCase()}\n${pathWithQuery}`;
}

/** Hex HMAC-SHA256 signature for a request (client side / tests). */
function signRequest(secret, timestamp, method, pathWithQuery) {
  return crypto.createHmac('sha256', String(secret)).update(canonicalString(timestamp, method, pathWithQuery), 'utf8').digest('hex');
}

function verifySignature({ secret, timestamp, signature, method, pathWithQuery, nowSeconds, maxSkewSeconds = MAX_SKEW_SECONDS }) {
  if (typeof timestamp !== 'string' || !/^\d{1,12}$/.test(timestamp)) return { ok: false, reason: 'bad_timestamp' };
  if (typeof signature !== 'string' || !/^[0-9a-fA-F]{64}$/.test(signature)) return { ok: false, reason: 'bad_signature' };
  const ts = Number(timestamp);
  if (Math.abs(nowSeconds - ts) > maxSkewSeconds) return { ok: false, reason: 'stale_timestamp' };
  const expected = signRequest(secret, timestamp, method, pathWithQuery);
  if (!constantTimeEqualHex(expected, signature.toLowerCase())) return { ok: false, reason: 'bad_signature' };
  return { ok: true };
}

/** Small bounded cache of already-seen (timestamp, signature) pairs. */
class NonceCache {
  constructor(maxEntries = 5000) {
    this.max = maxEntries;
    this.map = new Map();
  }

  /** Returns true if the key is fresh (and records it); false if it is a replay. */
  checkAndStore(key, nowSeconds, ttlSeconds) {
    const existing = this.map.get(key);
    if (existing !== undefined && existing > nowSeconds) return false;
    if (this.map.size >= this.max) this.prune(nowSeconds);
    this.map.set(key, nowSeconds + ttlSeconds);
    return true;
  }

  prune(nowSeconds) {
    for (const [k, exp] of this.map) if (exp <= nowSeconds) this.map.delete(k);
    // Still full: drop oldest insertions. Entries only exist for validly signed requests.
    while (this.map.size >= this.max) this.map.delete(this.map.keys().next().value);
  }
}

/** Fixed-window rate limiter keyed by token id (or client address for failed auth). */
class RateLimiter {
  constructor({ limit = 60, windowSeconds = 60, maxKeys = 10000 } = {}) {
    this.limit = limit;
    this.windowMs = windowSeconds * 1000;
    this.maxKeys = maxKeys;
    this.map = new Map();
  }

  hit(key, nowMs) {
    let b = this.map.get(key);
    if (!b || nowMs - b.start >= this.windowMs) {
      if (this.map.size >= this.maxKeys) this.prune(nowMs);
      b = { start: nowMs, count: 0 };
      this.map.set(key, b);
    }
    b.count += 1;
    if (b.count > this.limit) {
      const retryAfter = Math.max(1, Math.ceil((b.start + this.windowMs - nowMs) / 1000));
      return { allowed: false, retryAfter };
    }
    return { allowed: true, retryAfter: 0, remaining: this.limit - b.count };
  }

  prune(nowMs) {
    for (const [k, b] of this.map) if (nowMs - b.start >= this.windowMs) this.map.delete(k);
    while (this.map.size >= this.maxKeys) this.map.delete(this.map.keys().next().value);
  }
}

/** Opaque pagination cursor: base64url(JSON {v, t, id}) of the last item returned. */
function encodeCursor(occurredAt, id) {
  return Buffer.from(JSON.stringify({ v: 1, t: occurredAt, id }), 'utf8').toString('base64url');
}

function decodeCursor(cursor) {
  if (typeof cursor !== 'string' || cursor.length === 0 || cursor.length > 512) return null;
  if (!/^[A-Za-z0-9_-]+$/.test(cursor)) return null;
  let obj;
  try {
    obj = JSON.parse(Buffer.from(cursor, 'base64url').toString('utf8'));
  } catch {
    return null;
  }
  if (!obj || typeof obj !== 'object' || obj.v !== 1) return null;
  if (typeof obj.id !== 'string' || obj.id.length === 0 || obj.id.length > 128) return null;
  if (typeof obj.t !== 'string' || obj.t.length > 40) return null;
  const tMs = Date.parse(obj.t);
  if (!Number.isFinite(tMs)) return null;
  return { tMs, id: obj.id };
}

/** "john@example.com" -> "j***@e***.com". Returns null when the input is not email-shaped. */
function maskEmail(email) {
  if (typeof email !== 'string') return null;
  const m = /^([^@\s]+)@([^@\s.]+)((?:\.[^@\s.]+)*)\.([^@\s.]+)$/.exec(email.trim());
  if (!m) return null;
  return `${m[1][0]}***@${m[2][0]}***.${m[4]}`.toLowerCase();
}

function isLoopbackAddress(addr) {
  if (typeof addr !== 'string') return false;
  const a = addr.startsWith('::ffff:') ? addr.slice(7) : addr;
  return a === '::1' || /^127(\.\d{1,3}){3}$/.test(a);
}

module.exports = {
  SCOPES,
  MAX_SKEW_SECONDS,
  sha256Hex,
  hashToken,
  generateToken,
  constantTimeEqualHex,
  normalizeTokens,
  extractBearer,
  verifyToken,
  hasScope,
  canonicalString,
  signRequest,
  verifySignature,
  NonceCache,
  RateLimiter,
  encodeCursor,
  decodeCursor,
  maskEmail,
  isLoopbackAddress,
};
