# ForgeDeck companion for FastAPI

`forgedeck_companion` is a small FastAPI router exposing the read-only ForgeDeck endpoints
(`/_forgedeck/v1/manifest|status|metrics|leads|events`). Contract: `../contract/README.md`.

Copy the `forgedeck_companion/` package into your product (ForgeDeck never does that for
you). Its only runtime dependency is FastAPI.

```python
import os
from fastapi import FastAPI
from forgedeck_companion import CompanionConfig, TokenRecord, create_router, load_release_file

app = FastAPI()
app.include_router(create_router(CompanionConfig(
    product_id="example-product",              # from your config, never from the request
    environment="production",                  # production | staging | development | preview | test
    capabilities={"status", "metrics"},        # everything else stays off
    tokens=[TokenRecord(id="forgedeck",        # only the SHA-256 of the token is stored
                        sha256=os.environ["FORGEDECK_TOKEN_SHA256"],
                        scopes={"status:read", "metrics:read"})],
    trust_proxy=True,                          # only if a proxy you control sets X-Forwarded-Proto
    release=load_release_file(os.environ.get("FORGEDECK_RELEASE_FILE", "forgedeck-release.json")),
    health=lambda: {"checks": [{"id": "database", "state": "healthy"}]},
    metrics=count_metrics,                     # (window, seconds) -> {"leads": 12, "signups": 9}; sync or async
    metrics_allowed=["leads", "signups"],
)))
```

Create a token and its hash:

```sh
python -c "from forgedeck_companion import generate_token, hash_token; t = generate_token(); print(t); print(hash_token(t))"
```

Options mirror the Node package: `signing_secret`, `require_https`, `trust_proxy`,
`rate_limit` / `rate_window_seconds`, `leads_masked_label`, `leads` / `events` / `instances`
providers (`leads(query)` receives `{"since", "until", "after", "limit"}` and returns item
dicts; only whitelisted fields are emitted). Defaults are deny: no tokens, no capabilities.

`forgedeck_companion.core` has no FastAPI dependency (token hashing, signing, rate
limiting, cursors, redaction) and can be reused with another framework.

The rate limiter and replay cache are in process memory: with several workers each keeps
its own counters. When running behind uvicorn's `--proxy-headers`, the scheme is already
rewritten by uvicorn; `trust_proxy` is for setups where it is not.

## Tests

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest
```

`tests/test_core.py` needs only pytest. `tests/test_router.py` needs FastAPI and httpx.
`tests/test_contract.py` needs jsonschema and validates the contract examples, this
router's responses, and (if `node` is on the PATH) the Node example server's responses
against `../contract/*.schema.json`.
