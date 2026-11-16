# ForgeDeck companions

Optional server-side packages that let a product you own tell ForgeDeck what is really
running: the deployed commit, health, and a few aggregate business counters. ForgeDeck
works without them; with one installed it reads trusted data from the running system
instead of inferring it.

A companion is a small **read-only** HTTP API under `/_forgedeck/v1`:
`manifest`, `status`, `metrics`, and optionally `leads` and `events`.

| Folder | What |
| --- | --- |
| `contract/` | The contract: routes, auth, scopes, signing, errors, versioning; JSON Schemas; examples; the CI deployment-fingerprint recipe |
| `node/` | Dependency-free middleware for `http` and Express-style apps, plus a runnable local test server |
| `python/` | FastAPI router (`forgedeck_companion`) |
| `wordpress/forgedeck-companion/` | WordPress plugin (REST namespace `forgedeck/v1`) |

## The rule: ForgeDeck never auto-installs companions

ForgeDeck does not copy these files into your repositories, open pull requests, install
plugins, or change server configuration. A companion reaches a product only when a person
decides to add it, reviews it, and deploys it through that product's normal process. The
app may point you to this folder; the installing is always yours.

## Security model in one paragraph

Default deny: nothing is served until a token is configured, and each capability is off
until enabled. `GET` only; no admin or mutation routes. Bearer tokens are stored as SHA-256
hashes, compared in constant time, scoped per capability, revocable and optionally
expiring. Optional HMAC request signing with a 300-second window and replay cache. HTTPS
required outside loopback. 60 requests/minute per token. Lead data is redacted to ids,
kinds and timestamps. `product_id` and `environment` come from server configuration only.
Logs never contain tokens. Details: `contract/README.md`.

## Rollout

1. **Read the contract** and decide which capabilities the product should expose. Start
   with `status` only.
2. **Add the fingerprint** to the product's CI (`contract/deployment-fingerprint.md`) so
   `/status` reports a real commit.
3. **Add the companion** in a normal pull request to the product's repository. Leave
   `leads` and `events` off unless you need them.
4. **Deploy to staging first.** Generate a staging token, store only its hash on the
   server, and check by hand:
   ```sh
   curl -s -H "Authorization: Bearer $TOKEN" https://staging.example.com/_forgedeck/v1/manifest
   curl -s -o /dev/null -w '%{http_code}\n' https://staging.example.com/_forgedeck/v1/status   # expect 401
   ```
5. **Connect ForgeDeck** to staging and confirm the commit and health it shows.
6. **Production:** a separate token with the narrowest scopes, per environment. Never reuse
   a token across products or environments.
7. Add capabilities one at a time, each with its scope added to a newly issued token.

Token rotation: issue the new token, update ForgeDeck, then revoke the old one.

## Rollback

Fastest first:

1. **Revoke the token** (set `revoked: true`, remove the record, or press Revoke in
   WordPress). Every request is refused immediately; no deploy needed where tokens live in
   configuration or the database.
2. **Disable capabilities** (set them to off). Routes answer 404.
3. **Remove the companion**: unmount the middleware/router and redeploy, or deactivate the
   WordPress plugin (uninstall also deletes its options).

Companions hold no state the product depends on and write nothing to your data, so removal
has no data migration. ForgeDeck then shows the product without companion data.

If a token may have leaked: revoke it first, then check the request logs (token ids and
paths are logged; token values never are).

## Running the tests

```sh
# Node (built-in test runner; no install step)
cd node && npm test

# Python (local virtualenv, git-ignored)
cd python && python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt && .venv/bin/python -m pytest

# WordPress plugin (standalone PHP; never needs or touches a WordPress site)
cd wordpress/forgedeck-companion && php tests/run-tests.php && php tests/run-rest-tests.php
find wordpress -name '*.php' -exec php -l {} \;
```

## Local test server

```sh
cd node && node example-server.js --port 8787 --token local-dev-token-0123456789 --test-controls
```

In-memory sample data (12 leads and 9 signups in the 24h window), bound to 127.0.0.1.
See `node/README.md` for the test controls (`POST /__test/add-lead`,
`POST /__test/health?state=unhealthy|healthy`) and `--sha`.
