# ForgeDeck companion contract v1

A companion is a small **read-only** HTTP API that a product you own exposes so the
ForgeDeck macOS app can read trusted runtime and business information straight from the
running system. This document is the contract; the packages in `../node`, `../python` and
`../wordpress` implement it.

- Base path: `/_forgedeck/v1` (WordPress: `/wp-json/forgedeck/v1`, see below)
- Methods: `GET` only. There are no admin or mutation routes, and none may be added under this prefix.
- Format: JSON, UTF-8. Timestamps are UTC ISO-8601 with second precision: `2026-11-15T16:00:00Z`.
- Every response carries `Cache-Control: no-store`.

## Routes

| Route | Scope | Capability | Purpose |
| --- | --- | --- | --- |
| `GET /_forgedeck/v1/manifest` | `status:read` | (none) | Product id, schema version, enabled capabilities, environment, component ids, safe metadata |
| `GET /_forgedeck/v1/status` | `status:read` | `status` | Release fingerprint, health state and check summaries, report time |
| `GET /_forgedeck/v1/metrics?window=24h` | `metrics:read` | `metrics` | Whitelisted counters for one window |
| `GET /_forgedeck/v1/leads?cursor=&limit=` | `leads:read` | `leads` | Optional. Redacted lead events |
| `GET /_forgedeck/v1/events?cursor=&limit=` | `events:read` | `events` | Optional. Change / incident / business events |

Schemas: `status.schema.json`, `manifest.schema.json`, `metrics.schema.json`,
`events.schema.json` (used by both `/leads` and `/events`), `error.schema.json`.
Examples (invented values, not live data): `examples/`.

### Default deny

1. Until at least one token is configured, **every** request gets `503 not_configured`.
2. Every capability (`status`, `metrics`, `leads`, `events`) is **off** until the operator
   switches it on. A route whose capability is off answers `404 not_found`, exactly like a
   route that does not exist.
3. The manifest needs no capability, only a valid token with `status:read`, so ForgeDeck
   can always discover what is enabled.
4. `product_id`, `environment` and `component_id` come from server configuration. Nothing
   in a request (query, header, body) can change them.

### `GET /status`

```json
{
  "schema_version": "1.0",
  "product_id": "example-product",
  "component_id": "backend",
  "environment": "production",
  "observed_at": "2026-11-15T16:00:00Z",
  "release": {"commit_sha": "0123456789abcdef0123456789abcdef01234567", "version": "1.8.2", "deployed_at": "2026-11-14T12:30:00Z"},
  "health": {"state": "healthy", "checks": [{"id": "database", "state": "healthy"}]},
  "metrics": {"leads_24h": 12, "signups_24h": 9},
  "capabilities": ["status", "metrics"]
}
```

- These nine keys are always present.
- `health.state` is `healthy`, `degraded` or `unhealthy`: the worst state among the checks.
  A check exposes only `id` and `state`, never error text, hostnames or connection strings.
- An unhealthy product still answers `200`; the HTTP status describes the companion, the
  body describes the product.
- `metrics` holds the 24h counters as `<name>_24h`. It is `{}` when the `metrics`
  capability is off or the token lacks `metrics:read`.
- `release.commit_sha`, `release.version` and `release.deployed_at` may each be `null`
  when the deployment has no fingerprint (see `deployment-fingerprint.md`).
- Optional keys: `release.build_id`, `release.built_at`, `booted_at` (process start), and
  `instances: [{"id": "web-1", "commit_sha": "..."}]` so a multi-instance deployment can
  report mixed revisions during a rollout.
- `environment` is one of `production`, `staging`, `development`, `preview`, `test`.

### `GET /manifest`

`schema_version`, `product_id`, `environment`, `observed_at`, `component_ids`,
`capabilities` (enabled ones), plus `scopes` (held by the presenting token), `windows`,
`signing_required`, `metadata` (operator-chosen safe strings) and `companion`
(implementation name and version).

### `GET /metrics?window=`

`window` is one of `24h`, `7d`, `30d`, `90d` (default `24h`). Anything else is
`400 invalid_window`.

```json
{"schema_version": "1.0", "product_id": "example-product", "environment": "production",
 "observed_at": "2026-11-15T16:00:00Z", "window": "24h", "source": "application",
 "metrics": {"leads": 12, "signups": 9}}
```

Only counters on the server-side allow-list are emitted; anything else the application
returns is dropped.

### `GET /leads` and `GET /events`

| Parameter | Rule |
| --- | --- |
| `limit` | Integer 1-100, default 50. Out of range: `400 invalid_limit` |
| `cursor` | Opaque value from a previous `next_cursor`. Malformed: `400 invalid_cursor` |
| `since`, `until` | Optional ISO-8601 timestamps. Default: the 90 days ending now. A range longer than 90 days: `400 invalid_range` |

```json
{"schema_version": "1.0", "product_id": "example-product", "environment": "production",
 "observed_at": "2026-11-15T16:00:00Z",
 "items": [{"id": "evt_lead_0001", "kind": "lead", "occurred_at": "2026-11-15T14:05:00Z",
            "source": "contact_form", "title": "New lead", "value_cents": null}],
 "next_cursor": null}
```

- `kind`: `lead`, `signup`, `paid_conversion`, `renewal`, `cancellation` on `/leads`;
  `/events` additionally allows `deploy` and `incident`.
- Items are ordered oldest first, ties broken by `id`. `next_cursor` is `null` when there
  is nothing more; otherwise pass it back as `?cursor=` for the next page.
- `id` is stable. Clients dedupe by `id`: re-reading a page, or polling again later from a
  saved cursor (or from the start), must never create duplicates.
- **Redaction.** An item has exactly `id`, `kind`, `occurred_at`, `source`, `title`,
  `value_cents`. There are no name, email, phone, address or IP fields, and the companion
  packages strip everything else the application hands them. The single exception is the
  opt-in `label` on `/leads`: a masked string such as `j***@e***.com`, emitted only when
  the operator explicitly enables it. `title` is operator-controlled text; do not put
  personal data in it.

## Authentication

```
Authorization: Bearer <token>
```

- Tokens are random (the packages generate 256-bit tokens prefixed `fdk_`). The server
  stores only the SHA-256 hex digest and compares digests in constant time.
- Tokens are never accepted in the query string.
- Each token has its own scopes: `status:read`, `metrics:read`, `leads:read`, `events:read`.
- A token may have an expiry and can be revoked. Rotate by adding the new token, updating
  ForgeDeck, then revoking the old one.

## Optional request signing

When the operator configures a signing secret, every request must also carry:

```
X-ForgeDeck-Timestamp: <unix seconds>
X-ForgeDeck-Signature: <hex HMAC-SHA256(secret, "<timestamp>\n<METHOD>\n<path-with-query>")>
```

- `<path-with-query>` is the request target exactly as sent, e.g.
  `/_forgedeck/v1/metrics?window=24h` (on WordPress `/wp-json/forgedeck/v1/metrics?window=24h`).
  A reverse proxy that rewrites the path must be accounted for by the client.
- The timestamp must be within 300 seconds of the server clock.
- A `(timestamp, signature)` pair is accepted once; repeats are rejected from a small
  replay cache. A client that sends the identical request twice within the same second
  must wait for the next second.
- Signing is in addition to the bearer token, never instead of it.
- Unlike the token, the signing secret has to be stored readable on the server.

Test vector (all three packages assert it):

```
secret     signing-secret-0123456789
timestamp  1794758400
method     GET
path       /_forgedeck/v1/metrics?window=24h
signature  8e06b08e0d1b608b4be2b998316ad034375c056a8b375707af02dfe86f31a01b
```

## Transport

HTTPS is required. Plain HTTP is accepted only from a loopback client (`127.0.0.0/8`,
`::1`). `X-Forwarded-Proto` is ignored unless the operator opts in to trusting a proxy they
control; with that opt-in, a forwarded `http` is refused even though the proxy itself
connects over loopback.

## Rate limiting

60 requests per minute per token by default. Over the limit: `429 rate_limited` with
`Retry-After: <seconds>`. Failed authentication attempts are limited per client address.

## Errors

Every non-2xx body is:

```json
{"schema_version": "1.0", "error": {"code": "insufficient_scope", "message": "Token lacks scope leads:read"}}
```

| Status | `error.code` | Meaning |
| --- | --- | --- |
| 400 | `invalid_window`, `invalid_limit`, `invalid_cursor`, `invalid_time`, `invalid_range`, `invalid_request` | Bad parameter |
| 401 | `unauthorized` | Token missing, malformed, unknown, revoked or expired (deliberately indistinguishable). Carries `WWW-Authenticate: Bearer` |
| 401 | `invalid_signature`, `replayed_request` | Signing is required and the signature is missing, wrong, stale or reused |
| 403 | `insufficient_scope` | Valid token without the route's scope |
| 403 | `https_required` | Plain HTTP from a non-loopback client |
| 404 | `not_found` | Unknown route, or the route's capability is disabled |
| 405 | `method_not_allowed` | Anything but `GET` (WordPress answers 404 instead) |
| 429 | `rate_limited` | Too many requests; see `Retry-After` |
| 500 | `internal_error` | A data provider failed. No detail is disclosed |
| 503 | `not_configured` | No token configured yet |

Checks run in this order: method, configured, HTTPS, token, rate limit, signature, route
and capability, scope, parameters. An unauthenticated caller therefore learns nothing about
which capabilities are enabled.

## Logging

Companions log one line per request: method, path **without** query string, status, token
*id*, duration. They never log tokens, token hashes, signatures, signing secrets or headers.

## Versioning

- The major version is in the path (`/v1`). `schema_version` is `"1.<minor>"`.
- Additive changes (new optional properties, new metrics, new optional routes) keep the
  major version and may raise the minor. **Clients must ignore unknown properties.**
- Removing or renaming a property, changing a type or meaning, or tightening auth
  semantics requires a new path (`/_forgedeck/v2`); v1 keeps working during the transition.
- New `kind` values are a minor change; clients should skip kinds they do not know.

## WordPress mapping

The WordPress plugin registers the same routes in the REST namespace `forgedeck/v1`:

| Contract | WordPress URL |
| --- | --- |
| `/_forgedeck/v1/status` | `https://example.com/wp-json/forgedeck/v1/status` |
| `/_forgedeck/v1/metrics?window=7d` | `https://example.com/wp-json/forgedeck/v1/metrics?window=7d` |

An optional rewrite (off by default) additionally serves `/_forgedeck/v1/...`. Differences
on WordPress: non-`GET` methods answer `404` (WordPress has no route for them), and
`/leads` and `/events` are empty unless site code supplies items through a filter.
