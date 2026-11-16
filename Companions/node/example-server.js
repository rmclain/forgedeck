#!/usr/bin/env node
'use strict';

// ForgeDeck companion example / local test server.
//
//   node example-server.js --port 8787 --token <token> [--test-controls] [--sha <sha>] [--fail-health]
//
// Serves manifest/status/metrics/leads/events from IN-MEMORY SAMPLE DATA (not live data).
// It always binds to 127.0.0.1. It is a development aid, not something to deploy.

const http = require('node:http');
const { createCompanion, SCOPES } = require('./index');
const { isLoopbackAddress } = require('./lib/security');

const HOST = '127.0.0.1';
const DEFAULT_SHA = '0123456789abcdef0123456789abcdef01234567';
const HOUR = 3600 * 1000;
const DAY = 24 * HOUR;

function parseArgs(argv) {
  const opts = {
    port: 8787,
    token: process.env.FORGEDECK_TOKEN || null,
    sha: DEFAULT_SHA,
    version: '1.8.2',
    productId: 'example-product',
    environment: 'development',
    testControls: false,
    failHealth: false,
    maskedLabels: false,
    signingSecret: null,
    quiet: false,
  };
  const valueFlags = {
    '--port': 'port',
    '--token': 'token',
    '--sha': 'sha',
    '--version': 'version',
    '--product-id': 'productId',
    '--environment': 'environment',
    '--signing-secret': 'signingSecret',
  };
  const boolFlags = { '--test-controls': 'testControls', '--fail-health': 'failHealth', '--masked-labels': 'maskedLabels', '--quiet': 'quiet' };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--help' || a === '-h') {
      opts.help = true;
    } else if (valueFlags[a]) {
      if (i + 1 >= argv.length) throw new Error(`${a} needs a value`);
      opts[valueFlags[a]] = argv[++i];
    } else if (boolFlags[a]) {
      opts[boolFlags[a]] = true;
    } else {
      throw new Error(`Unknown argument: ${a}`);
    }
  }
  opts.port = Number(opts.port);
  if (!Number.isInteger(opts.port) || opts.port < 0 || opts.port > 65535) throw new Error('--port must be 0-65535');
  if (!/^[0-9a-f]{7,40}$/i.test(opts.sha)) throw new Error('--sha must be 7-40 hex characters');
  return opts;
}

const USAGE = `Usage: node example-server.js --port 8787 --token <token> [options]

  --port <n>             Port on 127.0.0.1 (default 8787; 0 = random)
  --token <t>            Bearer token ForgeDeck must present (or env FORGEDECK_TOKEN); min 16 chars
  --sha <sha>            Commit SHA to report in /status (default ${DEFAULT_SHA})
  --version <v>          Version to report (default 1.8.2)
  --product-id <id>      product_id (default example-product)
  --environment <env>    production|staging|development|preview|test (default development)
  --test-controls        Enable LOCAL-ONLY test control routes:
                           POST /__test/add-lead
                           POST /__test/health?state=healthy|degraded|unhealthy
  --fail-health          Start with health reported as unhealthy
  --masked-labels        Include masked labels (j***@e***.com) on /leads items
  --signing-secret <s>   Require HMAC request signing with this secret (min 16 chars)
  --quiet                No request log lines
`;

/** In-memory sample data. 12 leads and 9 signups fall inside the 24h window at start-up. */
function createStore(startMs) {
  const events = [];
  let seq = 0;
  const add = (kind, occurredMs, extra) => {
    seq += 1;
    const ev = {
      id: `evt_${kind}_${String(seq).padStart(4, '0')}`,
      kind,
      occurred_at: new Date(occurredMs).toISOString(),
      source: kind === 'lead' ? 'contact_form' : kind === 'signup' ? 'signup_form' : 'system',
      // Sample address so the redaction path is exercised; it is never returned unmasked.
      email: kind === 'lead' || kind === 'signup' ? `sample${seq}@example.com` : undefined,
      ...extra,
    };
    events.push(ev);
    return ev;
  };
  // Older history (inside 7d, outside 24h): 5 leads, 3 signups.
  for (let i = 0; i < 5; i++) add('lead', startMs - (6 - i) * DAY);
  for (let i = 0; i < 3; i++) add('signup', startMs - (5 - i) * DAY - HOUR);
  add('deploy', startMs - 27.5 * HOUR, { title: 'Deployed 1.8.2', source: 'ci' });
  // Last 24h: 12 leads, 9 signups, all within the most recent ~12h.
  for (let i = 0; i < 12; i++) add('lead', startMs - (12 - i) * 55 * 60 * 1000);
  for (let i = 0; i < 9; i++) add('signup', startMs - (9 - i) * 70 * 60 * 1000 - 5 * 60 * 1000);
  return {
    events,
    add,
    count(kind, sinceMs) {
      return events.filter((e) => e.kind === kind && Date.parse(e.occurred_at) >= sinceMs).length;
    },
  };
}

function createExampleServer(options = {}) {
  const opts = { sha: DEFAULT_SHA, version: '1.8.2', productId: 'example-product', environment: 'development', ...options };
  if (typeof opts.token !== 'string' || opts.token.length < 16) throw new Error('A --token of at least 16 characters is required');
  const startMs = Date.now();
  const store = createStore(startMs);
  const state = { health: opts.failHealth ? 'unhealthy' : 'healthy' };

  const companion = createCompanion({
    productId: opts.productId,
    environment: opts.environment,
    componentId: 'backend',
    metadata: { display_name: 'Example Product (sample data)', data_kind: 'in_memory_sample' },
    capabilities: { status: true, metrics: true, leads: true, events: true },
    tokens: [{ id: 'example-token', token: opts.token, scopes: [...SCOPES] }],
    signing: opts.signingSecret ? { secret: opts.signingSecret } : undefined,
    leads: { maskedLabel: opts.maskedLabels === true },
    metrics: { allowed: ['leads', 'signups'], source: 'example-in-memory' },
    logger: opts.quiet ? false : undefined,
    providers: {
      release: () => ({ commit_sha: opts.sha, version: opts.version, deployed_at: new Date(startMs - 27.5 * HOUR).toISOString(), build_id: 'example-build-1' }),
      health: () => ({
        checks: [
          { id: 'database', state: state.health },
          { id: 'queue', state: 'healthy' },
        ],
      }),
      metrics: (_window, seconds) => {
        const since = Date.now() - seconds * 1000;
        return { leads: store.count('lead', since), signups: store.count('signup', since) };
      },
      leads: () => store.events.filter((e) => e.kind === 'lead' || e.kind === 'signup'),
      events: () => store.events,
    },
  });

  function json(res, status, body) {
    const payload = JSON.stringify(body);
    res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(payload), 'Cache-Control': 'no-store' });
    res.end(payload);
  }

  // ---- TEST CONTROLS (local only; never part of the companion contract) -------------------
  // Only reachable with --test-controls, only from loopback, only via POST, and never from a
  // browser page (requests carrying an Origin header are refused).
  function handleTestControl(req, res, path, query) {
    if (!isLoopbackAddress(req.socket.remoteAddress) || req.headers.origin) return json(res, 403, { ok: false, error: 'test controls are local-only' });
    if (req.method !== 'POST') return json(res, 405, { ok: false, error: 'use POST' });
    const totals = () => ({ leads_24h: store.count('lead', Date.now() - DAY), signups_24h: store.count('signup', Date.now() - DAY) });
    if (path === '/__test/add-lead') {
      const item = store.add('lead', Date.now(), { title: 'New lead' });
      return json(res, 200, { ok: true, test_control: true, added: { id: item.id, kind: item.kind, occurred_at: item.occurred_at }, totals: totals() });
    }
    if (path === '/__test/health') {
      const next = query.get('state');
      if (!['healthy', 'degraded', 'unhealthy'].includes(next)) return json(res, 400, { ok: false, error: 'state must be healthy, degraded or unhealthy' });
      if (next !== state.health) {
        store.add('incident', Date.now(), { title: next === 'healthy' ? 'Health recovered' : `Health ${next}: database check failing`, source: 'healthcheck' });
      }
      state.health = next;
      return json(res, 200, { ok: true, test_control: true, health: state.health });
    }
    return json(res, 404, { ok: false, error: 'unknown test control' });
  }

  const server = http.createServer((req, res) => {
    const url = String(req.url || '/');
    const qi = url.indexOf('?');
    const path = qi === -1 ? url : url.slice(0, qi);
    if (opts.testControls === true && path.startsWith('/__test/')) {
      return handleTestControl(req, res, path, new URLSearchParams(qi === -1 ? '' : url.slice(qi + 1)));
    }
    return companion(req, res);
  });

  return {
    server,
    store,
    state,
    listen(port = 0) {
      return new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(port, HOST, () => resolve(server.address().port));
      });
    },
    close() {
      return new Promise((resolve) => server.close(() => resolve()));
    },
  };
}

async function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (err) {
    process.stderr.write(`${err.message}\n\n${USAGE}`);
    process.exit(2);
  }
  if (opts.help) {
    process.stdout.write(USAGE);
    return;
  }
  let example;
  try {
    example = createExampleServer(opts);
  } catch (err) {
    process.stderr.write(`${err.message}\n\n${USAGE}`);
    process.exit(2);
  }
  const port = await example.listen(opts.port);
  const base = `http://${HOST}:${port}`;
  // The token itself is never printed.
  console.log(`ForgeDeck companion example server (in-memory SAMPLE data, not live data)`);
  console.log(`  base URL:   ${base}/_forgedeck/v1`);
  console.log(`  routes:     /manifest /status /metrics?window=24h /leads /events`);
  console.log(`  auth:       Authorization: Bearer <the --token value>${opts.signingSecret ? '  (+ HMAC signing required)' : ''}`);
  console.log(`  commit:     ${opts.sha}`);
  if (opts.testControls) {
    console.log(`  TEST CONTROLS ENABLED (local only):`);
    console.log(`    curl -X POST ${base}/__test/add-lead`);
    console.log(`    curl -X POST '${base}/__test/health?state=unhealthy'`);
    console.log(`    curl -X POST '${base}/__test/health?state=healthy'`);
  }
  const stop = () => example.close().then(() => process.exit(0));
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
}

if (require.main === module) {
  main();
}

module.exports = { createExampleServer, parseArgs };
