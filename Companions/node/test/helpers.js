'use strict';

const { createCompanion, SCOPES } = require('../index');

const TOKEN = 'fdk_test_token_0123456789abcdefghij';
const SHA = '0123456789abcdef0123456789abcdef01234567';
const NOW = Date.parse('2026-11-15T16:00:00Z');

/** Call the handler with minimal mock req/res objects; lets tests fake remote address and TLS. */
async function invoke(companion, { method = 'GET', url, headers = {}, token, remoteAddress = '127.0.0.1', encrypted = false, originalUrl } = {}) {
  const h = {};
  for (const [k, v] of Object.entries(headers)) h[k.toLowerCase()] = v;
  if (token) h.authorization = `Bearer ${token}`;
  const req = { method, url, headers: h, socket: { remoteAddress, encrypted } };
  if (originalUrl) req.originalUrl = originalUrl;
  const out = { status: null, headers: {}, raw: '', nextCalled: false };
  const res = {
    statusCode: 200,
    setHeader(k, v) {
      out.headers[k.toLowerCase()] = String(v);
    },
    end(payload) {
      out.status = this.statusCode;
      out.raw = payload || '';
    },
  };
  await companion(req, res, () => {
    out.nextCalled = true;
  });
  out.body = out.raw ? JSON.parse(out.raw) : null;
  return out;
}

function sampleEvents(now = NOW) {
  const items = [];
  for (let i = 0; i < 12; i++) {
    items.push({
      id: `evt_lead_${String(i + 1).padStart(3, '0')}`,
      kind: 'lead',
      occurred_at: new Date(now - (i + 1) * 3600 * 1000).toISOString(),
      source: 'contact_form',
      title: 'New lead',
      email: `person${i}@example.com`,
      name: 'Jane Private',
      phone: '+1 555 0100',
      ip: '203.0.113.9',
    });
  }
  for (let i = 0; i < 9; i++) {
    items.push({ id: `evt_signup_${String(i + 1).padStart(3, '0')}`, kind: 'signup', occurred_at: new Date(now - (i + 1) * 7200 * 1000).toISOString(), source: 'signup_form', email: `user${i}@example.org` });
  }
  return items;
}

function makeCompanion(overrides = {}) {
  const logs = [];
  const clock = { now: NOW };
  const events = sampleEvents();
  const companion = createCompanion({
    productId: 'example-product',
    environment: 'production',
    componentId: 'backend',
    capabilities: { status: true, metrics: true, leads: true, events: true },
    tokens: [{ id: 'main', token: TOKEN, scopes: [...SCOPES] }],
    logger: (line) => logs.push(line),
    now: () => clock.now,
    metrics: { allowed: ['leads', 'signups'], source: 'test-db' },
    providers: {
      release: { commit_sha: SHA, version: '1.8.2', deployed_at: '2026-11-14T12:30:00Z' },
      health: () => ({ checks: [{ id: 'database', state: 'healthy' }] }),
      metrics: () => ({ leads: 12, signups: 9, secret_internal_counter: 999, revenue_by_customer: { acme: 1 } }),
      leads: () => events.filter((e) => e.kind === 'lead' || e.kind === 'signup'),
      events: () => [...events, { id: 'evt_deploy_001', kind: 'deploy', occurred_at: '2026-11-14T12:30:00Z', source: 'ci', title: 'Deployed 1.8.2' }],
    },
    ...overrides,
  });
  return { companion, logs, clock, events };
}

module.exports = { invoke, makeCompanion, sampleEvents, TOKEN, SHA, NOW };
