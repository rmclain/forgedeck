# ForgeDeck companion for Node

Read-only ForgeDeck endpoints (`/_forgedeck/v1/manifest|status|metrics|leads|events`) for
plain `http` servers and Express-style apps. Node built-ins only, no dependencies.
Contract: `../contract/README.md`.

Copy this folder into your product (ForgeDeck never does that for you) and wire it up:

```js
const { createCompanion, loadReleaseFile } = require('./forgedeck-companion');

const companion = createCompanion({
  productId: 'example-product',          // from your config, never from the request
  environment: 'production',             // production | staging | development | preview | test
  componentId: 'backend',
  capabilities: { status: true, metrics: true },   // everything else stays off
  tokens: [
    // Store only the SHA-256 of the token: node -e "console.log(require('./forgedeck-companion').hashToken(process.argv[1]))" <token>
    { id: 'forgedeck', sha256: process.env.FORGEDECK_TOKEN_SHA256, scopes: ['status:read', 'metrics:read'] },
  ],
  trustProxy: true,                      // only if a proxy you control sets X-Forwarded-Proto
  metrics: { allowed: ['leads', 'signups'], source: 'app-db' },
  providers: {
    release: loadReleaseFile(process.env.FORGEDECK_RELEASE_FILE || 'forgedeck-release.json'),
    health: async () => ({ checks: [{ id: 'database', state: (await db.ping()) ? 'healthy' : 'unhealthy' }] }),
    metrics: async (window, seconds) => ({ leads: await countLeads(seconds), signups: await countSignups(seconds) }),
  },
});

app.use(companion);                      // Express-style: other paths fall through to next()
// or: http.createServer(companion)      // plain http: other paths get a 404
```

Generate a token with `node -e "console.log(require('./forgedeck-companion').generateToken())"`,
give it to ForgeDeck, and keep only its hash on the server.

## Options

| Option | Default | Notes |
| --- | --- | --- |
| `productId`, `environment` | required | Validated at start-up |
| `componentId`, `componentIds` | `backend` | |
| `capabilities` | all off | Only a literal `true` enables one |
| `tokens` | none (every request gets 503) | `{ id, sha256, scopes, expiresAt?, revoked? }`; `token` (plaintext) is accepted for local development and hashed immediately |
| `signing.secret` | off | When set, HMAC request signing is required |
| `requireHttps` | `true` | Plain HTTP only from loopback |
| `trustProxy` | `false` | Honour `X-Forwarded-Proto` |
| `rateLimit` | `{ limit: 60, windowSeconds: 60 }` | Per token, in memory, per process |
| `leads.maskedLabel` | `false` | Adds `label: "j***@e***.com"` from the item's `email` |
| `metrics.allowed` | `leads, signups, paid_conversions, renewals, cancellations` | Other counters are dropped |
| `providers.leads` / `providers.events` | none | `({ since, until, after, limit }) => items`; return `{ id, kind, occurred_at, source, title?, value_cents?, email? }`. Only whitelisted fields leave the process; `email` is used solely for the opt-in masked label |
| `providers.instances` | none | `() => [{ id, commit_sha }]` |
| `logger` | `console.log` | One line per request, never tokens; `false` to silence |

The rate limiter and replay cache live in process memory: with several processes each
keeps its own counters.

## Tests

```sh
npm test          # same as: node --test test/
```

## Example / local test server

Serves in-memory **sample data** (not live data) on 127.0.0.1 only:

```sh
node example-server.js --port 8787 --token local-dev-token-0123456789 --test-controls
```

```sh
curl -s -H 'Authorization: Bearer local-dev-token-0123456789' http://127.0.0.1:8787/_forgedeck/v1/status
curl -s -H 'Authorization: Bearer local-dev-token-0123456789' 'http://127.0.0.1:8787/_forgedeck/v1/metrics?window=24h'   # leads 12, signups 9
```

| Flag | Effect |
| --- | --- |
| `--port <n>` | Port (default 8787) |
| `--token <t>` | Bearer token to require, min 16 chars (or env `FORGEDECK_TOKEN`) |
| `--sha <sha>` | Commit SHA reported by `/status` |
| `--test-controls` | Enable the local-only test control routes below |
| `--fail-health` | Start with health `unhealthy` |
| `--masked-labels` | Add masked labels to `/leads` |
| `--signing-secret <s>` | Require HMAC request signing |
| `--version`, `--product-id`, `--environment`, `--quiet` | Self-explanatory |

Test controls (only with `--test-controls`; loopback only; `POST` only; refused when an
`Origin` header is present; not part of the companion contract):

```sh
curl -X POST http://127.0.0.1:8787/__test/add-lead                    # appends one lead: leads 12 -> 13
curl -X POST 'http://127.0.0.1:8787/__test/health?state=unhealthy'    # database check fails
curl -X POST 'http://127.0.0.1:8787/__test/health?state=healthy'      # recovery
```

`/status` keeps answering `200` while unhealthy; the failure is in `health.state`.
Each health change also appends an `incident` event.
