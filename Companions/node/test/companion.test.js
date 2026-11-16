'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { createCompanion, SCOPES, hashToken, signRequest } = require('../index');
const { invoke, makeCompanion, TOKEN, SHA, NOW } = require('./helpers');

const BASE = '/_forgedeck/v1';

// ---------- default deny ----------

test('default deny: nothing is served until a token is configured', async () => {
  const companion = createCompanion({ productId: 'example-product', environment: 'production', capabilities: { status: true }, logger: false });
  for (const route of ['manifest', 'status', 'metrics', 'leads', 'events']) {
    const r = await invoke(companion, { url: `${BASE}/${route}`, token: TOKEN });
    assert.equal(r.status, 503, route);
    assert.equal(r.body.error.code, 'not_configured');
    assert.equal(r.body.product_id, undefined);
  }
});

test('default deny: capabilities are off unless explicitly enabled', async () => {
  const { companion } = makeCompanion({ capabilities: undefined });
  for (const route of ['status', 'metrics', 'leads', 'events']) {
    const r = await invoke(companion, { url: `${BASE}/${route}`, token: TOKEN });
    assert.equal(r.status, 404, route);
  }
  const m = await invoke(companion, { url: `${BASE}/manifest`, token: TOKEN });
  assert.equal(m.status, 200);
  assert.deepEqual(m.body.capabilities, []);
});

test('default deny: truthy-but-not-true capability values do not enable anything', async () => {
  const { companion } = makeCompanion({ capabilities: { status: 'yes', metrics: 1 } });
  assert.equal((await invoke(companion, { url: `${BASE}/status`, token: TOKEN })).status, 404);
  assert.equal((await invoke(companion, { url: `${BASE}/metrics`, token: TOKEN })).status, 404);
});

test('only enabled capabilities are served', async () => {
  const { companion } = makeCompanion({ capabilities: { status: true } });
  assert.equal((await invoke(companion, { url: `${BASE}/status`, token: TOKEN })).status, 200);
  assert.equal((await invoke(companion, { url: `${BASE}/leads`, token: TOKEN })).status, 404);
});

test('no mutation routes: every non-GET method is refused', async () => {
  const { companion } = makeCompanion();
  for (const method of ['POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS']) {
    for (const route of ['status', 'leads', 'admin', 'tokens']) {
      const r = await invoke(companion, { method, url: `${BASE}/${route}`, token: TOKEN });
      assert.equal(r.status, 405, `${method} ${route}`);
      assert.equal(r.headers.allow, 'GET');
    }
  }
});

test('unknown routes are 404', async () => {
  const { companion } = makeCompanion();
  for (const p of ['', '/', '/admin', '/status/', '/status/extra', '/tokens', '/__proto__', '/constructor']) {
    const r = await invoke(companion, { url: `${BASE}${p}`, token: TOKEN });
    assert.equal(r.status, 404, p);
  }
});

// ---------- authentication & scopes ----------

test('401 for missing, malformed and wrong tokens', async () => {
  const { companion } = makeCompanion();
  const cases = [{}, { headers: { Authorization: 'Bearer wrong-token-000000000000' } }, { headers: { Authorization: `Basic ${TOKEN}` } }, { headers: { Authorization: TOKEN } }, { url: `${BASE}/status?token=${TOKEN}` }];
  for (const c of cases) {
    const r = await invoke(companion, { url: `${BASE}/status`, ...c });
    assert.equal(r.status, 401);
    assert.equal(r.body.error.code, 'unauthorized');
    assert.equal(r.headers['www-authenticate'], 'Bearer');
    assert.equal(r.body.release, undefined);
  }
});

test('401 for revoked and expired tokens', async () => {
  const { companion, clock } = makeCompanion({
    tokens: [
      { id: 'revoked', token: 'revoked-token-0123456789', scopes: [...SCOPES], revoked: true },
      { id: 'expiring', token: 'expiring-token-0123456789', scopes: [...SCOPES], expiresAt: new Date(NOW + 1000).toISOString() },
    ],
  });
  assert.equal((await invoke(companion, { url: `${BASE}/status`, token: 'revoked-token-0123456789' })).status, 401);
  assert.equal((await invoke(companion, { url: `${BASE}/status`, token: 'expiring-token-0123456789' })).status, 200);
  clock.now = NOW + 1000;
  assert.equal((await invoke(companion, { url: `${BASE}/status`, token: 'expiring-token-0123456789' })).status, 401);
});

test('a token configured by SHA-256 hash authenticates; the hash itself does not', async () => {
  const { companion } = makeCompanion({ tokens: [{ id: 'hashed', sha256: hashToken(TOKEN), scopes: ['status:read'] }] });
  assert.equal((await invoke(companion, { url: `${BASE}/status`, token: TOKEN })).status, 200);
  assert.equal((await invoke(companion, { url: `${BASE}/status`, token: hashToken(TOKEN) })).status, 401);
});

test('403 when the token lacks the scope for a route', async () => {
  const { companion } = makeCompanion({ tokens: [{ id: 'status-only', token: TOKEN, scopes: ['status:read'] }] });
  assert.equal((await invoke(companion, { url: `${BASE}/status`, token: TOKEN })).status, 200);
  assert.equal((await invoke(companion, { url: `${BASE}/manifest`, token: TOKEN })).status, 200);
  for (const route of ['metrics', 'leads', 'events']) {
    const r = await invoke(companion, { url: `${BASE}/${route}`, token: TOKEN });
    assert.equal(r.status, 403, route);
    assert.equal(r.body.error.code, 'insufficient_scope');
    assert.equal(r.body.items, undefined);
    assert.equal(r.body.metrics, undefined);
  }
});

test('each route requires its own scope', async () => {
  const want = { manifest: 'status:read', status: 'status:read', metrics: 'metrics:read', leads: 'leads:read', events: 'events:read' };
  for (const scope of SCOPES) {
    const { companion } = makeCompanion({ tokens: [{ id: 't', token: TOKEN, scopes: [scope] }] });
    for (const [route, needed] of Object.entries(want)) {
      const r = await invoke(companion, { url: `${BASE}/${route}`, token: TOKEN });
      assert.equal(r.status, needed === scope ? 200 : 403, `${scope} -> ${route}`);
    }
  }
});

test('status omits metrics for a token without metrics:read', async () => {
  const { companion } = makeCompanion({ tokens: [{ id: 'status-only', token: TOKEN, scopes: ['status:read'] }] });
  const r = await invoke(companion, { url: `${BASE}/status`, token: TOKEN });
  assert.deepEqual(r.body.metrics, {});
});

// ---------- response shapes ----------

test('status has the canonical shape', async () => {
  const { companion } = makeCompanion();
  const r = await invoke(companion, { url: `${BASE}/status`, token: TOKEN });
  assert.equal(r.status, 200);
  assert.equal(r.headers['content-type'], 'application/json; charset=utf-8');
  assert.equal(r.headers['cache-control'], 'no-store');
  const { booted_at: bootedAt, ...canonical } = r.body;
  assert.match(bootedAt, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  assert.deepEqual(canonical, {
    schema_version: '1.0',
    product_id: 'example-product',
    component_id: 'backend',
    environment: 'production',
    observed_at: '2026-11-15T16:00:00Z',
    release: { commit_sha: SHA, version: '1.8.2', deployed_at: '2026-11-14T12:30:00Z' },
    health: { state: 'healthy', checks: [{ id: 'database', state: 'healthy' }] },
    metrics: { leads_24h: 12, signups_24h: 9 },
    capabilities: ['status', 'metrics', 'leads', 'events'],
  });
});

test('status health aggregates to the worst check and hides check details', async () => {
  const { companion } = makeCompanion({
    providers: {
      health: () => ({
        checks: [
          { id: 'database', state: 'healthy', error: 'postgres://user:pw@db.internal/app' },
          { id: 'queue', state: 'degraded' },
          { id: 'cache', state: 'weird' },
        ],
      }),
    },
  });
  const r = await invoke(companion, { url: `${BASE}/status`, token: TOKEN });
  assert.equal(r.body.health.state, 'unhealthy');
  assert.deepEqual(r.body.health.checks, [
    { id: 'database', state: 'healthy' },
    { id: 'queue', state: 'degraded' },
    { id: 'cache', state: 'unhealthy' },
  ]);
  assert.ok(!r.raw.includes('postgres://'));
  assert.deepEqual(r.body.release, { commit_sha: null, version: null, deployed_at: null });
});

test('status reports unhealthy (not a 500) when the health provider throws', async () => {
  const { companion } = makeCompanion({
    providers: {
      health: () => {
        throw new Error('db password=hunter2 refused');
      },
    },
  });
  const r = await invoke(companion, { url: `${BASE}/status`, token: TOKEN });
  assert.equal(r.status, 200);
  assert.equal(r.body.health.state, 'unhealthy');
  assert.ok(!r.raw.includes('hunter2'));
});

test('status can report mixed revisions via instances', async () => {
  const other = 'fedcba9876543210fedcba9876543210fedcba98';
  const { companion } = makeCompanion({
    providers: {
      release: { commit_sha: SHA },
      instances: () => [
        { id: 'web-1', commit_sha: SHA, hostname: 'ip-10-0-0-5.internal' },
        { id: 'web-2', commit_sha: other },
      ],
    },
  });
  const r = await invoke(companion, { url: `${BASE}/status`, token: TOKEN });
  assert.deepEqual(r.body.instances, [
    { id: 'web-1', commit_sha: SHA },
    { id: 'web-2', commit_sha: other },
  ]);
});

test('manifest lists product, environment, components, capabilities and safe metadata', async () => {
  const { companion } = makeCompanion({ componentIds: ['backend', 'worker'], metadata: { display_name: 'Example', 'Bad Key': 'x', nested: { a: 1 } } });
  const r = await invoke(companion, { url: `${BASE}/manifest`, token: TOKEN });
  assert.equal(r.status, 200);
  assert.equal(r.body.schema_version, '1.0');
  assert.equal(r.body.product_id, 'example-product');
  assert.equal(r.body.environment, 'production');
  assert.deepEqual(r.body.component_ids, ['backend', 'worker']);
  assert.deepEqual(r.body.capabilities, ['status', 'metrics', 'leads', 'events']);
  assert.deepEqual(r.body.windows, ['24h', '7d', '30d', '90d']);
  assert.deepEqual(r.body.metadata, { display_name: 'Example' });
  assert.equal(r.body.signing_required, false);
  assert.ok(!r.raw.includes(TOKEN));
  assert.ok(!r.raw.includes(hashToken(TOKEN)));
});

test('product_id and environment come from server config, never from the request', async () => {
  const { companion } = makeCompanion();
  const headers = { 'X-ForgeDeck-Product-Id': 'evil', 'X-ForgeDeck-Environment': 'staging', 'X-Product-Id': 'evil' };
  for (const route of ['manifest', 'status', 'metrics', 'leads', 'events']) {
    const r = await invoke(companion, { url: `${BASE}/${route}?product_id=evil&environment=staging&component_id=evil`, token: TOKEN, headers });
    assert.equal(r.status, 200, route);
    assert.equal(r.body.product_id, 'example-product');
    assert.equal(r.body.environment, 'production');
    assert.ok(!r.raw.includes('evil'));
  }
});

test('config validation rejects bad product ids and environments', () => {
  assert.throws(() => createCompanion({ productId: 'Bad Product!', environment: 'production' }), /productId/);
  assert.throws(() => createCompanion({ productId: 'ok', environment: 'prod' }), /environment/);
  assert.throws(() => createCompanion({ productId: 'ok', environment: 'production', capabilities: { admin: true } }), /unknown capability/);
  assert.throws(() => createCompanion({ productId: 'ok', environment: 'production', signing: { secret: 'short' } }), /signing/);
});

// ---------- metrics ----------

test('metrics: allowed windows only, whitelisted counters only', async () => {
  const { companion } = makeCompanion();
  for (const w of ['24h', '7d', '30d', '90d']) {
    const r = await invoke(companion, { url: `${BASE}/metrics?window=${w}`, token: TOKEN });
    assert.equal(r.status, 200, w);
    assert.deepEqual(r.body, {
      schema_version: '1.0',
      product_id: 'example-product',
      environment: 'production',
      observed_at: '2026-11-15T16:00:00Z',
      window: w,
      source: 'test-db',
      metrics: { leads: 12, signups: 9 },
    });
  }
  const dflt = await invoke(companion, { url: `${BASE}/metrics`, token: TOKEN });
  assert.equal(dflt.body.window, '24h');
  for (const w of ['1h', '365d', '91d', '', '24H', '24h%20', 'all', '7d,30d', '__proto__', 'constructor']) {
    const r = await invoke(companion, { url: `${BASE}/metrics?window=${w}`, token: TOKEN });
    assert.equal(r.status, 400, `window=${w}`);
    assert.equal(r.body.error.code, 'invalid_window');
  }
});

test('metrics: provider errors become a generic 500 with no detail', async () => {
  const { companion } = makeCompanion({
    providers: {
      metrics: () => {
        throw new Error('SELECT failed: password=hunter2');
      },
    },
  });
  const r = await invoke(companion, { url: `${BASE}/metrics`, token: TOKEN });
  assert.equal(r.status, 500);
  assert.equal(r.body.error.code, 'internal_error');
  assert.ok(!r.raw.includes('hunter2'));
});

// ---------- leads & events ----------

test('leads: no personal contact fields by default', async () => {
  const { companion } = makeCompanion();
  const r = await invoke(companion, { url: `${BASE}/leads`, token: TOKEN });
  assert.equal(r.status, 200);
  assert.equal(r.body.items.length, 21);
  for (const item of r.body.items) {
    assert.deepEqual(Object.keys(item).sort(), ['id', 'kind', 'occurred_at', 'source', 'title', 'value_cents']);
  }
  for (const needle of ['@', 'example.com', 'Jane', '555', '203.0.113', 'email', 'phone', 'label']) {
    assert.ok(!r.raw.includes(needle), `response leaked "${needle}"`);
  }
  assert.equal(r.body.next_cursor, null);
});

test('leads: masked label only when explicitly enabled, and never the raw address', async () => {
  const { companion } = makeCompanion({ leads: { maskedLabel: true } });
  const r = await invoke(companion, { url: `${BASE}/leads?limit=100`, token: TOKEN });
  const lead = r.body.items.find((i) => i.kind === 'lead');
  assert.equal(lead.label, 'p***@e***.com');
  assert.ok(!r.raw.includes('person'));
  assert.ok(!r.raw.includes('Jane'));
  // Events never carry labels, even with the option on.
  const ev = await invoke(companion, { url: `${BASE}/events?limit=100`, token: TOKEN });
  assert.ok(!ev.raw.includes('label'));
});

test('leads: limit is bounded to 1..100', async () => {
  const { companion } = makeCompanion();
  assert.equal((await invoke(companion, { url: `${BASE}/leads?limit=100`, token: TOKEN })).status, 200);
  assert.equal((await invoke(companion, { url: `${BASE}/leads?limit=1`, token: TOKEN })).body.items.length, 1);
  for (const bad of ['0', '101', '1000', '-1', 'abc', '1.5', '', '1e2']) {
    const r = await invoke(companion, { url: `${BASE}/leads?limit=${bad}`, token: TOKEN });
    assert.equal(r.status, 400, `limit=${bad}`);
    assert.equal(r.body.error.code, 'invalid_limit');
  }
});

test('leads: cursor pagination walks every item exactly once, oldest first', async () => {
  const { companion } = makeCompanion();
  const seen = [];
  let cursor = null;
  let pages = 0;
  do {
    const url = `${BASE}/leads?limit=5${cursor ? `&cursor=${cursor}` : ''}`;
    const r = await invoke(companion, { url, token: TOKEN });
    assert.equal(r.status, 200);
    assert.ok(r.body.items.length <= 5);
    seen.push(...r.body.items);
    cursor = r.body.next_cursor;
    pages += 1;
  } while (cursor && pages < 20);
  assert.equal(pages, 5);
  assert.equal(seen.length, 21);
  assert.equal(new Set(seen.map((i) => i.id)).size, 21);
  const times = seen.map((i) => Date.parse(i.occurred_at));
  assert.deepEqual(times, [...times].sort((a, b) => a - b));
});

test('leads: malformed cursors are rejected', async () => {
  const { companion } = makeCompanion();
  for (const bad of ['garbage', '', 'e30', '../../etc/passwd', 'a'.repeat(600)]) {
    const r = await invoke(companion, { url: `${BASE}/leads?cursor=${encodeURIComponent(bad)}`, token: TOKEN });
    assert.equal(r.status, 400, bad.slice(0, 20));
    assert.equal(r.body.error.code, 'invalid_cursor');
  }
});

test('leads: time range is bounded to 90 days', async () => {
  const { companion } = makeCompanion();
  const ok = await invoke(companion, { url: `${BASE}/leads?since=2026-08-17T16:00:00Z&until=2026-11-15T16:00:00Z`, token: TOKEN });
  assert.equal(ok.status, 200);
  const tooWide = await invoke(companion, { url: `${BASE}/leads?since=2026-08-17T15:59:59Z&until=2026-11-15T16:00:00Z`, token: TOKEN });
  assert.equal(tooWide.status, 400);
  assert.equal(tooWide.body.error.code, 'invalid_range');
  const inverted = await invoke(companion, { url: `${BASE}/leads?since=2026-11-15T16:00:00Z&until=2026-11-14T16:00:00Z`, token: TOKEN });
  assert.equal(inverted.status, 400);
  const garbage = await invoke(companion, { url: `${BASE}/leads?since=yesterday`, token: TOKEN });
  assert.equal(garbage.status, 400);
  assert.equal(garbage.body.error.code, 'invalid_time');
  const narrow = await invoke(companion, { url: `${BASE}/leads?since=2026-11-15T13:30:00Z`, token: TOKEN });
  assert.deepEqual(
    narrow.body.items.map((i) => i.id),
    ['evt_lead_002', 'evt_signup_001', 'evt_lead_001'], // same timestamp: id is the tie-breaker
  );
});

test('leads: items older than the default 90-day range are not returned', async () => {
  const { companion } = makeCompanion({
    providers: {
      leads: () => [
        { id: 'evt_old', kind: 'lead', occurred_at: '2026-01-01T00:00:00Z', source: 'contact_form' },
        { id: 'evt_new', kind: 'lead', occurred_at: '2026-11-15T12:00:00Z', source: 'contact_form' },
      ],
    },
  });
  const r = await invoke(companion, { url: `${BASE}/leads`, token: TOKEN });
  assert.deepEqual(
    r.body.items.map((i) => i.id),
    ['evt_new'],
  );
});

test('leads: malformed provider rows and non-lead kinds are dropped', async () => {
  const { companion } = makeCompanion({
    providers: {
      leads: () => [
        null,
        { id: 'has space', kind: 'lead', occurred_at: '2026-11-15T12:00:00Z' },
        { id: 'evt_x', kind: 'password_reset', occurred_at: '2026-11-15T12:00:00Z' },
        { id: 'evt_d', kind: 'deploy', occurred_at: '2026-11-15T12:00:00Z' },
        { id: 'evt_y', kind: 'lead', occurred_at: 'not a date' },
        { id: 'evt_ok', kind: 'paid_conversion', occurred_at: '2026-11-15T12:00:00Z', source: 'stripe', value_cents: 4900, customer_email: 'a@b.com' },
      ],
    },
  });
  const r = await invoke(companion, { url: `${BASE}/leads`, token: TOKEN });
  assert.deepEqual(r.body.items, [{ id: 'evt_ok', kind: 'paid_conversion', occurred_at: '2026-11-15T12:00:00Z', source: 'stripe', title: 'Paid conversion', value_cents: 4900 }]);
});

test('events: stable ids across repeated reads, deploy/incident kinds allowed', async () => {
  const { companion } = makeCompanion();
  const a = await invoke(companion, { url: `${BASE}/events?limit=100`, token: TOKEN });
  const b = await invoke(companion, { url: `${BASE}/events?limit=100`, token: TOKEN });
  assert.equal(a.status, 200);
  assert.equal(a.body.items.length, 22);
  assert.deepEqual(
    a.body.items.map((i) => i.id),
    b.body.items.map((i) => i.id),
  );
  assert.equal(new Set(a.body.items.map((i) => i.id)).size, 22);
  assert.equal(a.body.items[0].kind, 'deploy');
  assert.ok(!a.raw.includes('@'));
});

// ---------- request signing ----------

function signed(secret, url, nowMs, method = 'GET') {
  const ts = String(Math.floor(nowMs / 1000));
  return { 'X-ForgeDeck-Timestamp': ts, 'X-ForgeDeck-Signature': signRequest(secret, ts, method, url) };
}

test('signing: required once a secret is configured', async () => {
  const secret = 'signing-secret-0123456789';
  const { companion } = makeCompanion({ signing: { secret } });
  const url = `${BASE}/metrics?window=7d`;
  const unsigned = await invoke(companion, { url, token: TOKEN });
  assert.equal(unsigned.status, 401);
  assert.equal(unsigned.body.error.code, 'invalid_signature');
  const ok = await invoke(companion, { url, token: TOKEN, headers: signed(secret, url, NOW) });
  assert.equal(ok.status, 200);
  const manifest = await invoke(companion, { url: `${BASE}/manifest`, token: TOKEN, headers: signed(secret, `${BASE}/manifest`, NOW) });
  assert.equal(manifest.body.signing_required, true);
  assert.ok(!manifest.raw.includes(secret));
});

test('signing: a valid signature does not replace the bearer token', async () => {
  const secret = 'signing-secret-0123456789';
  const { companion } = makeCompanion({ signing: { secret } });
  const url = `${BASE}/status`;
  const r = await invoke(companion, { url, headers: signed(secret, url, NOW) });
  assert.equal(r.status, 401);
  assert.equal(r.body.error.code, 'unauthorized');
});

test('signing: replayed (timestamp, signature) pairs are rejected', async () => {
  const secret = 'signing-secret-0123456789';
  const { companion, clock } = makeCompanion({ signing: { secret } });
  const url = `${BASE}/status`;
  const headers = signed(secret, url, NOW);
  assert.equal((await invoke(companion, { url, token: TOKEN, headers })).status, 200);
  const replay = await invoke(companion, { url, token: TOKEN, headers });
  assert.equal(replay.status, 401);
  assert.equal(replay.body.error.code, 'replayed_request');
  clock.now = NOW + 120_000;
  assert.equal((await invoke(companion, { url, token: TOKEN, headers })).status, 401, 'still a replay inside the skew window');
  assert.equal((await invoke(companion, { url, token: TOKEN, headers: signed(secret, url, clock.now) })).status, 200, 'fresh signature works');
});

test('signing: stale timestamps, wrong secret, and signatures for another path/method are rejected', async () => {
  const secret = 'signing-secret-0123456789';
  const { companion } = makeCompanion({ signing: { secret } });
  const url = `${BASE}/metrics?window=24h`;
  const cases = [
    signed(secret, url, NOW - 301_000),
    signed(secret, url, NOW + 301_000),
    signed('wrong-secret-0123456789abc', url, NOW),
    signed(secret, `${BASE}/metrics?window=90d`, NOW),
    signed(secret, `${BASE}/leads`, NOW),
    signed(secret, url, NOW, 'POST'),
    { 'X-ForgeDeck-Timestamp': String(Math.floor(NOW / 1000)) },
    { 'X-ForgeDeck-Timestamp': 'now', 'X-ForgeDeck-Signature': 'f'.repeat(64) },
  ];
  for (const headers of cases) {
    const r = await invoke(companion, { url, token: TOKEN, headers });
    assert.equal(r.status, 401);
    assert.equal(r.body.error.code, 'invalid_signature');
  }
  assert.equal((await invoke(companion, { url, token: TOKEN, headers: signed(secret, url, NOW - 299_000) })).status, 200);
});

// ---------- transport ----------

test('HTTPS is required for non-loopback clients', async () => {
  const { companion } = makeCompanion();
  const url = `${BASE}/status`;
  const plain = await invoke(companion, { url, token: TOKEN, remoteAddress: '203.0.113.7' });
  assert.equal(plain.status, 403);
  assert.equal(plain.body.error.code, 'https_required');
  assert.equal(plain.body.release, undefined);
  assert.equal((await invoke(companion, { url, token: TOKEN, remoteAddress: '203.0.113.7', encrypted: true })).status, 200);
  for (const addr of ['127.0.0.1', '::1', '::ffff:127.0.0.1']) {
    assert.equal((await invoke(companion, { url, token: TOKEN, remoteAddress: addr })).status, 200, addr);
  }
});

test('X-Forwarded-Proto is ignored unless trustProxy is enabled', async () => {
  const url = `${BASE}/status`;
  const spoof = { 'X-Forwarded-Proto': 'https' };
  const { companion: untrusting } = makeCompanion();
  assert.equal((await invoke(untrusting, { url, token: TOKEN, remoteAddress: '203.0.113.7', headers: spoof })).status, 403);

  const { companion: trusting } = makeCompanion({ trustProxy: true });
  assert.equal((await invoke(trusting, { url, token: TOKEN, remoteAddress: '10.0.0.2', headers: spoof })).status, 200);
  // Behind a local reverse proxy the socket is loopback, but the original request was plain HTTP.
  const viaProxyPlain = await invoke(trusting, { url, token: TOKEN, remoteAddress: '127.0.0.1', headers: { 'X-Forwarded-Proto': 'http' } });
  assert.equal(viaProxyPlain.status, 403);
});

test('requireHttps can be turned off explicitly for private networks', async () => {
  const { companion } = makeCompanion({ requireHttps: false });
  assert.equal((await invoke(companion, { url: `${BASE}/status`, token: TOKEN, remoteAddress: '10.0.0.9' })).status, 200);
});

// ---------- rate limiting ----------

test('rate limit: 429 with Retry-After per token, resets after the window', async () => {
  const { companion, clock } = makeCompanion({ rateLimit: { limit: 5, windowSeconds: 60 } });
  const url = `${BASE}/status`;
  for (let i = 0; i < 5; i++) assert.equal((await invoke(companion, { url, token: TOKEN })).status, 200);
  clock.now = NOW + 15_000;
  const limited = await invoke(companion, { url, token: TOKEN });
  assert.equal(limited.status, 429);
  assert.equal(limited.body.error.code, 'rate_limited');
  assert.equal(limited.headers['retry-after'], '45');
  clock.now = NOW + 60_000;
  assert.equal((await invoke(companion, { url, token: TOKEN })).status, 200);
});

test('rate limit: default is 60 requests per minute', async () => {
  const { companion } = makeCompanion();
  const url = `${BASE}/manifest`;
  for (let i = 0; i < 60; i++) assert.equal((await invoke(companion, { url, token: TOKEN })).status, 200);
  assert.equal((await invoke(companion, { url, token: TOKEN })).status, 429);
});

test('rate limit: tokens are limited independently; failed auth is limited per client address', async () => {
  const other = 'fdk_other_token_0123456789abcdefghi';
  const { companion } = makeCompanion({
    rateLimit: { limit: 3, windowSeconds: 60 },
    tokens: [
      { id: 'a', token: TOKEN, scopes: [...SCOPES] },
      { id: 'b', token: other, scopes: [...SCOPES] },
    ],
  });
  const url = `${BASE}/status`;
  for (let i = 0; i < 3; i++) await invoke(companion, { url, token: TOKEN });
  assert.equal((await invoke(companion, { url, token: TOKEN })).status, 429);
  assert.equal((await invoke(companion, { url, token: other })).status, 200);
  for (let i = 0; i < 3; i++) assert.equal((await invoke(companion, { url, token: 'guess-0000000000000000' })).status, 401);
  assert.equal((await invoke(companion, { url, token: 'guess-0000000000000000' })).status, 429);
});

// ---------- logging ----------

test('request log lines never contain tokens, hashes, signatures or query strings', async () => {
  const secret = 'signing-secret-0123456789';
  const { companion, logs } = makeCompanion({ signing: { secret } });
  const url = `${BASE}/metrics?window=24h`;
  const headers = signed(secret, url, NOW);
  await invoke(companion, { url, token: TOKEN, headers });
  await invoke(companion, { url: `${BASE}/status?token=${TOKEN}&access_token=${TOKEN}`, token: TOKEN });
  await invoke(companion, { url: `${BASE}/status`, token: 'wrong-token-zzzzzzzzzzzzzzzz' });
  await invoke(companion, { url: `${BASE}/status\r\nInjected: line` });
  assert.equal(logs.length, 4);
  const joined = logs.join('\n');
  for (const needle of [TOKEN, hashToken(TOKEN), secret, headers['X-ForgeDeck-Signature'], 'wrong-token', 'window=', 'Bearer', 'Injected: line']) {
    assert.ok(!joined.includes(needle), `log leaked "${needle}"`);
  }
  assert.match(logs[0], /^\[forgedeck-companion\] GET \/_forgedeck\/v1\/metrics 200 token=main \d+ms$/);
  assert.match(logs[2], / 401 token=- /);
  for (const line of logs) assert.ok(!/[\r\n]/.test(line));
});

// ---------- mounting ----------

test('Express-style: non-companion paths call next(); mounted paths use originalUrl', async () => {
  const { companion } = makeCompanion();
  const passthrough = await invoke(companion, { url: '/api/users', token: TOKEN });
  assert.equal(passthrough.nextCalled, true);
  assert.equal(passthrough.status, null);
  const similar = await invoke(companion, { url: '/_forgedeck/v1x/status', token: TOKEN });
  assert.equal(similar.nextCalled, true);
  const mounted = await invoke(companion, { url: '/status', originalUrl: `${BASE}/status`, token: TOKEN });
  assert.equal(mounted.status, 200);
  assert.equal(mounted.nextCalled, false);
});

test('plain http listener: real requests over a loopback socket', async (t) => {
  const { companion } = makeCompanion();
  const server = http.createServer(companion);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => server.close());
  const base = `http://127.0.0.1:${server.address().port}`;
  const auth = { Authorization: `Bearer ${TOKEN}` };

  const status = await fetch(`${base}${BASE}/status`, { headers: auth });
  assert.equal(status.status, 200);
  assert.equal((await status.json()).release.commit_sha, SHA);

  assert.equal((await fetch(`${base}${BASE}/status`)).status, 401);
  assert.equal((await fetch(`${base}/other`, { headers: auth })).status, 404);
  assert.equal((await fetch(`${base}${BASE}/status`, { method: 'POST', headers: auth })).status, 405);
  assert.equal((await fetch(`${base}${BASE}/metrics?window=1y`, { headers: auth })).status, 400);
});
