'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const sec = require('../lib/security');

test('hashToken is SHA-256 hex and generateToken is random', () => {
  assert.equal(sec.hashToken('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  const a = sec.generateToken();
  const b = sec.generateToken();
  assert.match(a, /^fdk_[A-Za-z0-9_-]{43}$/);
  assert.notEqual(a, b);
});

test('normalizeTokens stores only the hash, never the plaintext', () => {
  const [rec] = sec.normalizeTokens([{ id: 'a', token: 'plaintext-token-123456', scopes: ['status:read'] }]);
  assert.equal(rec.sha256, sec.hashToken('plaintext-token-123456'));
  assert.ok(!JSON.stringify(rec).includes('plaintext-token-123456'));
  assert.equal(rec.token, undefined);
});

test('normalizeTokens rejects bad records', () => {
  assert.throws(() => sec.normalizeTokens([{ id: 'a', sha256: 'nothex', scopes: [] }]), /64 hex/);
  assert.throws(() => sec.normalizeTokens([{ id: 'a', token: 'short', scopes: [] }]), /too short/);
  assert.throws(() => sec.normalizeTokens([{ id: 'a', token: 'long-enough-token-1234', scopes: ['admin:write'] }]), /unknown scope/);
  assert.throws(() => sec.normalizeTokens([{ id: 'a', token: 'long-enough-token-1234' }, { id: 'a', token: 'long-enough-token-5678' }]), /duplicate/);
  assert.deepEqual(sec.normalizeTokens(undefined), []);
});

test('extractBearer', () => {
  assert.equal(sec.extractBearer('Bearer abc.DEF-123_x'), 'abc.DEF-123_x');
  assert.equal(sec.extractBearer('bearer abc'), null);
  assert.equal(sec.extractBearer('Basic abc'), null);
  assert.equal(sec.extractBearer('Bearer '), null);
  assert.equal(sec.extractBearer('Bearer a b'), null);
  assert.equal(sec.extractBearer(undefined), null);
  assert.equal(sec.extractBearer('Bearer ' + 'a'.repeat(2000)), null);
});

test('verifyToken: ok, unknown, revoked, expired', () => {
  const now = Date.parse('2026-11-15T16:00:00Z');
  const records = sec.normalizeTokens([
    { id: 'good', token: 'good-token-0123456789', scopes: ['status:read'] },
    { id: 'revoked', token: 'revoked-token-0123456789', scopes: ['status:read'], revoked: true },
    { id: 'expired', token: 'expired-token-0123456789', scopes: ['status:read'], expiresAt: '2026-11-15T15:59:59Z' },
    { id: 'future', token: 'future-token-0123456789', scopes: ['status:read'], expiresAt: '2026-12-01T00:00:00Z' },
  ]);
  assert.equal(sec.verifyToken('good-token-0123456789', records, now).ok, true);
  assert.equal(sec.verifyToken('future-token-0123456789', records, now).ok, true);
  assert.deepEqual(sec.verifyToken('nope-token-0123456789', records, now), { ok: false, reason: 'unknown' });
  assert.equal(sec.verifyToken('revoked-token-0123456789', records, now).reason, 'revoked');
  assert.equal(sec.verifyToken('expired-token-0123456789', records, now).reason, 'expired');
  assert.equal(sec.verifyToken(null, records, now).reason, 'missing');
  assert.equal(sec.verifyToken('', records, now).reason, 'missing');
  // Presenting the stored hash instead of the token must not authenticate.
  assert.equal(sec.verifyToken(records[0].sha256, records, now).ok, false);
});

test('hasScope', () => {
  const [rec] = sec.normalizeTokens([{ id: 'a', token: 'good-token-0123456789', scopes: ['status:read'] }]);
  assert.equal(sec.hasScope(rec, 'status:read'), true);
  assert.equal(sec.hasScope(rec, 'leads:read'), false);
  assert.equal(sec.hasScope(null, 'status:read'), false);
});

test('signature: canonical string, verify, skew, tamper', () => {
  const secret = 'signing-secret-0123456789';
  const now = 1794758400;
  const path = '/_forgedeck/v1/metrics?window=24h';
  assert.equal(sec.canonicalString('1794758400', 'get', path), '1794758400\nGET\n/_forgedeck/v1/metrics?window=24h');
  const sig = sec.signRequest(secret, String(now), 'GET', path);
  // Same vector as contract/README.md and the Python/PHP test suites.
  assert.equal(sig, '8e06b08e0d1b608b4be2b998316ad034375c056a8b375707af02dfe86f31a01b');
  const base = { secret, timestamp: String(now), signature: sig, method: 'GET', pathWithQuery: path, nowSeconds: now };
  assert.equal(sec.verifySignature(base).ok, true);
  assert.equal(sec.verifySignature({ ...base, signature: sig.toUpperCase() }).ok, true);
  assert.equal(sec.verifySignature({ ...base, nowSeconds: now + 300 }).ok, true);
  assert.equal(sec.verifySignature({ ...base, nowSeconds: now + 301 }).reason, 'stale_timestamp');
  assert.equal(sec.verifySignature({ ...base, nowSeconds: now - 301 }).reason, 'stale_timestamp');
  assert.equal(sec.verifySignature({ ...base, pathWithQuery: '/_forgedeck/v1/metrics?window=7d' }).reason, 'bad_signature');
  assert.equal(sec.verifySignature({ ...base, method: 'POST' }).reason, 'bad_signature');
  assert.equal(sec.verifySignature({ ...base, secret: 'another-secret-0123456789' }).reason, 'bad_signature');
  assert.equal(sec.verifySignature({ ...base, signature: 'zz' }).reason, 'bad_signature');
  assert.equal(sec.verifySignature({ ...base, signature: undefined }).reason, 'bad_signature');
  assert.equal(sec.verifySignature({ ...base, timestamp: 'abc' }).reason, 'bad_timestamp');
  assert.equal(sec.verifySignature({ ...base, timestamp: undefined }).reason, 'bad_timestamp');
});

test('NonceCache rejects replays and stays bounded', () => {
  const c = new sec.NonceCache(3);
  assert.equal(c.checkAndStore('a', 100, 600), true);
  assert.equal(c.checkAndStore('a', 101, 600), false);
  assert.equal(c.checkAndStore('a', 701, 600), true, 'expired entries may be reused');
  for (const k of ['b', 'c', 'd', 'e']) c.checkAndStore(k, 702, 600);
  assert.ok(c.map.size <= 3);
});

test('RateLimiter: limit, Retry-After, window reset', () => {
  const rl = new sec.RateLimiter({ limit: 3, windowSeconds: 60 });
  const t0 = 1_000_000;
  assert.equal(rl.hit('k', t0).allowed, true);
  assert.equal(rl.hit('k', t0 + 1000).allowed, true);
  assert.equal(rl.hit('k', t0 + 2000).allowed, true);
  const blocked = rl.hit('k', t0 + 20_000);
  assert.equal(blocked.allowed, false);
  assert.equal(blocked.retryAfter, 40);
  assert.equal(rl.hit('other', t0 + 20_000).allowed, true, 'keys are independent');
  assert.equal(rl.hit('k', t0 + 60_000).allowed, true, 'new window');
});

test('cursor round trip and rejection of garbage', () => {
  const c = sec.encodeCursor('2026-11-15T15:00:00Z', 'evt_lead_001');
  assert.match(c, /^[A-Za-z0-9_-]+$/);
  assert.deepEqual(sec.decodeCursor(c), { tMs: Date.parse('2026-11-15T15:00:00Z'), id: 'evt_lead_001' });
  for (const bad of ['', 'not base64!!', 'e30', Buffer.from('{"v":1,"t":"nope","id":"x"}').toString('base64url'), Buffer.from('{"v":2,"t":"2026-11-15T15:00:00Z","id":"x"}').toString('base64url'), 'a'.repeat(600), null, 42]) {
    assert.equal(sec.decodeCursor(bad), null);
  }
});

test('maskEmail', () => {
  assert.equal(sec.maskEmail('john@example.com'), 'j***@e***.com');
  assert.equal(sec.maskEmail('Ann.Smith@Mail.Example.co.uk'), 'a***@m***.uk');
  assert.equal(sec.maskEmail('not-an-email'), null);
  assert.equal(sec.maskEmail('a@b'), null);
  assert.equal(sec.maskEmail(undefined), null);
});

test('isLoopbackAddress', () => {
  for (const a of ['127.0.0.1', '127.1.2.3', '::1', '::ffff:127.0.0.1']) assert.equal(sec.isLoopbackAddress(a), true, a);
  for (const a of ['10.0.0.1', '203.0.113.5', '::ffff:10.0.0.1', '1127.0.0.1', '', undefined]) assert.equal(sec.isLoopbackAddress(a), false, String(a));
});
