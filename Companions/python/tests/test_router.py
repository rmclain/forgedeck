"""Behaviour tests for the FastAPI router (mirrors node/test/companion.test.js)."""

import json
from datetime import datetime, timedelta, timezone

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from forgedeck_companion import SCOPES, CompanionConfig, TokenRecord, create_router, hash_token, sign_request

BASE = "/_forgedeck/v1"
TOKEN = "fdk_test_token_0123456789abcdefghij"
SHA = "0123456789abcdef0123456789abcdef01234567"
NOW_DT = datetime(2026, 11, 15, 16, 0, 0, tzinfo=timezone.utc)
NOW = NOW_DT.timestamp()
SECRET = "signing-secret-0123456789"


def sample_events():
    items = []
    for i in range(12):
        items.append(
            {
                "id": f"evt_lead_{i + 1:03d}",
                "kind": "lead",
                "occurred_at": NOW_DT - timedelta(hours=i + 1),
                "source": "contact_form",
                "title": "New lead",
                "email": f"person{i}@example.com",
                "name": "Jane Private",
                "phone": "+1 555 0100",
                "ip": "203.0.113.9",
            }
        )
    for i in range(9):
        items.append({"id": f"evt_signup_{i + 1:03d}", "kind": "signup", "occurred_at": (NOW_DT - timedelta(hours=2 * (i + 1))).isoformat().replace("+00:00", "Z"), "source": "signup_form", "email": f"user{i}@example.org"})
    return items


class Harness:
    def __init__(self, client_addr=("127.0.0.1", 50000), base_url="http://testserver", **overrides):
        self.logs = []
        self.clock = [NOW]
        events = sample_events()
        settings = dict(
            product_id="example-product",
            environment="production",
            component_id="backend",
            capabilities={"status", "metrics", "leads", "events"},
            tokens=[TokenRecord.from_plaintext("main", TOKEN, SCOPES)],
            logger=self.logs.append,
            now=lambda: self.clock[0],
            metrics_allowed=["leads", "signups"],
            metrics_source="test-db",
            release={"commit_sha": SHA, "version": "1.8.2", "deployed_at": "2026-11-14T12:30:00Z"},
            health=lambda: {"checks": [{"id": "database", "state": "healthy"}]},
            metrics=lambda window, seconds: {"leads": 12, "signups": 9, "secret_internal_counter": 999, "by_customer": {"acme": 1}},
            leads=lambda q: [e for e in events if e["kind"] in ("lead", "signup")],
            events=lambda q: events + [{"id": "evt_deploy_001", "kind": "deploy", "occurred_at": "2026-11-14T12:30:00Z", "source": "ci", "title": "Deployed 1.8.2"}],
        )
        settings.update(overrides)
        app = FastAPI()
        app.include_router(create_router(CompanionConfig(**settings)))

        @app.get("/api/users")
        def users():
            return {"ok": True}

        self.client = TestClient(app, base_url=base_url, client=client_addr)

    def get(self, path, token=TOKEN, headers=None, method="GET"):
        h = dict(headers or {})
        if token:
            h["Authorization"] = f"Bearer {token}"
        return self.client.request(method, path, headers=h)


def signed(url, now=NOW, secret=SECRET, method="GET"):
    ts = str(int(now))
    return {"X-ForgeDeck-Timestamp": ts, "X-ForgeDeck-Signature": sign_request(secret, ts, method, url)}


# ---------- default deny ----------


def test_default_deny_nothing_served_without_a_token():
    h = Harness(tokens=[])
    for route in ["manifest", "status", "metrics", "leads", "events"]:
        r = h.get(f"{BASE}/{route}")
        assert r.status_code == 503, route
        assert r.json()["error"]["code"] == "not_configured"
        assert "product_id" not in r.json()


def test_default_config_has_no_tokens_and_no_capabilities():
    cfg = CompanionConfig(product_id="example-product", environment="production")
    assert cfg.tokens == [] and cfg.capabilities == []


def test_default_deny_capabilities_off_unless_enabled():
    h = Harness(capabilities=set())
    for route in ["status", "metrics", "leads", "events"]:
        assert h.get(f"{BASE}/{route}").status_code == 404, route
    m = h.get(f"{BASE}/manifest")
    assert m.status_code == 200 and m.json()["capabilities"] == []


def test_only_enabled_capabilities_are_served():
    h = Harness(capabilities={"status"})
    assert h.get(f"{BASE}/status").status_code == 200
    assert h.get(f"{BASE}/leads").status_code == 404


def test_no_mutation_routes():
    h = Harness()
    for method in ["POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]:
        for route in ["status", "leads", "admin", "tokens"]:
            r = h.get(f"{BASE}/{route}", method=method)
            assert r.status_code == 405, f"{method} {route}"
            assert r.headers["allow"] == "GET"


def test_unknown_routes_are_404():
    h = Harness()
    for p in ["", "/admin", "/status/extra", "/tokens", "/__proto__"]:
        assert h.get(f"{BASE}{p}").status_code == 404, p


def test_unknown_routes_still_require_auth():
    h = Harness()
    assert h.get(f"{BASE}/admin", token=None).status_code == 401


# ---------- authentication & scopes ----------


def test_401_for_missing_malformed_and_wrong_tokens():
    h = Harness()
    cases = [
        dict(token=None),
        dict(token="wrong-token-000000000000"),
        dict(token=None, headers={"Authorization": f"Basic {TOKEN}"}),
        dict(token=None, headers={"Authorization": TOKEN}),
    ]
    for c in cases:
        r = h.get(f"{BASE}/status", **c)
        assert r.status_code == 401
        assert r.json()["error"]["code"] == "unauthorized"
        assert r.headers["www-authenticate"] == "Bearer"
        assert "release" not in r.json()
    assert h.get(f"{BASE}/status?token={TOKEN}", token=None).status_code == 401


def test_401_for_revoked_and_expired_tokens():
    h = Harness(
        tokens=[
            TokenRecord.from_plaintext("revoked", "revoked-token-0123456789", SCOPES, revoked=True),
            TokenRecord.from_plaintext("expiring", "expiring-token-0123456789", SCOPES, expires_at=NOW_DT + timedelta(seconds=1)),
        ]
    )
    assert h.get(f"{BASE}/status", token="revoked-token-0123456789").status_code == 401
    assert h.get(f"{BASE}/status", token="expiring-token-0123456789").status_code == 200
    h.clock[0] = NOW + 1
    assert h.get(f"{BASE}/status", token="expiring-token-0123456789").status_code == 401


def test_token_configured_by_hash_authenticates_but_hash_does_not():
    h = Harness(tokens=[TokenRecord(id="hashed", sha256=hash_token(TOKEN), scopes=frozenset({"status:read"}))])
    assert h.get(f"{BASE}/status").status_code == 200
    assert h.get(f"{BASE}/status", token=hash_token(TOKEN)).status_code == 401


def test_403_when_scope_missing():
    h = Harness(tokens=[TokenRecord.from_plaintext("status-only", TOKEN, ["status:read"])])
    assert h.get(f"{BASE}/status").status_code == 200
    assert h.get(f"{BASE}/manifest").status_code == 200
    for route in ["metrics", "leads", "events"]:
        r = h.get(f"{BASE}/{route}")
        assert r.status_code == 403, route
        assert r.json()["error"]["code"] == "insufficient_scope"
        assert "items" not in r.json() and "metrics" not in r.json()
    assert h.get(f"{BASE}/status").json()["metrics"] == {}


@pytest.mark.parametrize("scope", SCOPES)
def test_each_route_requires_its_own_scope(scope):
    want = {"manifest": "status:read", "status": "status:read", "metrics": "metrics:read", "leads": "leads:read", "events": "events:read"}
    h = Harness(tokens=[TokenRecord.from_plaintext("t", TOKEN, [scope])])
    for route, needed in want.items():
        assert h.get(f"{BASE}/{route}").status_code == (200 if needed == scope else 403), f"{scope} -> {route}"


# ---------- response shapes ----------


def test_status_has_the_canonical_shape():
    h = Harness()
    r = h.get(f"{BASE}/status")
    assert r.status_code == 200
    assert r.headers["cache-control"] == "no-store"
    body = r.json()
    assert body.pop("booted_at").endswith("Z")
    assert body == {
        "schema_version": "1.0",
        "product_id": "example-product",
        "component_id": "backend",
        "environment": "production",
        "observed_at": "2026-11-15T16:00:00Z",
        "release": {"commit_sha": SHA, "version": "1.8.2", "deployed_at": "2026-11-14T12:30:00Z"},
        "health": {"state": "healthy", "checks": [{"id": "database", "state": "healthy"}]},
        "metrics": {"leads_24h": 12, "signups_24h": 9},
        "capabilities": ["status", "metrics", "leads", "events"],
    }


def test_status_health_aggregates_and_hides_details():
    h = Harness(
        release=None,
        health=lambda: {"checks": [{"id": "database", "state": "healthy", "error": "postgres://user:pw@db.internal/app"}, {"id": "queue", "state": "degraded"}]},
    )
    r = h.get(f"{BASE}/status")
    assert r.json()["health"] == {"state": "degraded", "checks": [{"id": "database", "state": "healthy"}, {"id": "queue", "state": "degraded"}]}
    assert "postgres://" not in r.text
    assert r.json()["release"] == {"commit_sha": None, "version": None, "deployed_at": None}


def test_status_reports_unhealthy_when_health_provider_raises():
    def boom():
        raise RuntimeError("db password=hunter2 refused")

    r = Harness(health=boom).get(f"{BASE}/status")
    assert r.status_code == 200
    assert r.json()["health"]["state"] == "unhealthy"
    assert "hunter2" not in r.text


def test_status_instances_and_async_providers():
    other = "fedcba9876543210fedcba9876543210fedcba98"

    async def instances():
        return [{"id": "web-1", "commit_sha": SHA, "hostname": "ip-10-0-0-5.internal"}, {"id": "web-2", "commit_sha": other}]

    async def metrics(window, seconds):
        return {"leads": 3, "signups": 1}

    h = Harness(instances=instances, metrics=metrics)
    body = h.get(f"{BASE}/status").json()
    assert body["instances"] == [{"id": "web-1", "commit_sha": SHA}, {"id": "web-2", "commit_sha": other}]
    assert body["metrics"] == {"leads_24h": 3, "signups_24h": 1}


def test_manifest():
    h = Harness(component_ids=["backend", "worker"], metadata={"display_name": "Example", "Bad Key": "x", "nested": {"a": 1}})
    r = h.get(f"{BASE}/manifest")
    body = r.json()
    assert body["schema_version"] == "1.0"
    assert body["product_id"] == "example-product"
    assert body["environment"] == "production"
    assert body["component_ids"] == ["backend", "worker"]
    assert body["capabilities"] == ["status", "metrics", "leads", "events"]
    assert body["windows"] == ["24h", "7d", "30d", "90d"]
    assert body["metadata"] == {"display_name": "Example"}
    assert body["signing_required"] is False
    assert TOKEN not in r.text and hash_token(TOKEN) not in r.text


def test_product_and_environment_come_from_config_not_request():
    h = Harness()
    headers = {"X-ForgeDeck-Product-Id": "evil", "X-ForgeDeck-Environment": "staging", "X-Product-Id": "evil"}
    for route in ["manifest", "status", "metrics", "leads", "events"]:
        r = h.get(f"{BASE}/{route}?product_id=evil&environment=staging&component_id=evil", headers=headers)
        assert r.status_code == 200, route
        assert r.json()["product_id"] == "example-product"
        assert r.json()["environment"] == "production"
        assert "evil" not in r.text


def test_config_validation():
    with pytest.raises(ValueError):
        CompanionConfig(product_id="Bad Product!", environment="production")
    with pytest.raises(ValueError):
        CompanionConfig(product_id="ok", environment="prod")
    with pytest.raises(ValueError):
        CompanionConfig(product_id="ok", environment="production", capabilities={"admin"})
    with pytest.raises(ValueError):
        CompanionConfig(product_id="ok", environment="production", capabilities="status")
    with pytest.raises(ValueError):
        CompanionConfig(product_id="ok", environment="production", signing_secret="short")
    with pytest.raises(ValueError):
        CompanionConfig(product_id="ok", environment="production", tokens=[{"id": "x", "token": "plaintext-in-a-dict-123"}])


# ---------- metrics ----------


def test_metrics_windows_and_whitelist():
    h = Harness()
    for w in ["24h", "7d", "30d", "90d"]:
        r = h.get(f"{BASE}/metrics?window={w}")
        assert r.status_code == 200, w
        assert r.json() == {
            "schema_version": "1.0",
            "product_id": "example-product",
            "environment": "production",
            "observed_at": "2026-11-15T16:00:00Z",
            "window": w,
            "source": "test-db",
            "metrics": {"leads": 12, "signups": 9},
        }
    assert h.get(f"{BASE}/metrics").json()["window"] == "24h"
    for w in ["1h", "365d", "91d", "", "24H", "24h%20", "all", "7d,30d", "__class__"]:
        r = h.get(f"{BASE}/metrics?window={w}")
        assert r.status_code == 400, w
        assert r.json()["error"]["code"] == "invalid_window"


def test_metrics_provider_errors_are_generic_500():
    def boom(window, seconds):
        raise RuntimeError("SELECT failed: password=hunter2")

    r = Harness(metrics=boom).get(f"{BASE}/metrics")
    assert r.status_code == 500
    assert r.json()["error"]["code"] == "internal_error"
    assert "hunter2" not in r.text


# ---------- leads & events ----------


def test_leads_have_no_personal_contact_fields_by_default():
    r = Harness().get(f"{BASE}/leads")
    assert r.status_code == 200
    items = r.json()["items"]
    assert len(items) == 21
    for item in items:
        assert sorted(item) == ["id", "kind", "occurred_at", "source", "title", "value_cents"]
    for needle in ["@", "example.com", "Jane", "555", "203.0.113", "email", "phone", "label"]:
        assert needle not in r.text, needle
    assert r.json()["next_cursor"] is None


def test_leads_masked_label_only_when_enabled():
    h = Harness(leads_masked_label=True)
    r = h.get(f"{BASE}/leads?limit=100")
    lead = next(i for i in r.json()["items"] if i["kind"] == "lead")
    assert lead["label"] == "p***@e***.com"
    assert "person" not in r.text and "Jane" not in r.text
    assert "label" not in h.get(f"{BASE}/events?limit=100").text


def test_leads_limit_is_bounded():
    h = Harness(rate_limit=1000)
    assert h.get(f"{BASE}/leads?limit=100").status_code == 200
    assert len(h.get(f"{BASE}/leads?limit=1").json()["items"]) == 1
    for bad in ["0", "101", "1000", "-1", "abc", "1.5", "", "1e2", "%D9%A1"]:
        r = h.get(f"{BASE}/leads?limit={bad}")
        assert r.status_code == 400, bad
        assert r.json()["error"]["code"] == "invalid_limit"


def test_leads_cursor_pagination_walks_every_item_once():
    h = Harness()
    seen, cursor, pages = [], None, 0
    while pages < 20:
        url = f"{BASE}/leads?limit=5" + (f"&cursor={cursor}" if cursor else "")
        body = h.get(url).json()
        assert len(body["items"]) <= 5
        seen += body["items"]
        cursor = body["next_cursor"]
        pages += 1
        if not cursor:
            break
    assert pages == 5
    assert len(seen) == 21 and len({i["id"] for i in seen}) == 21
    times = [i["occurred_at"] for i in seen]
    assert times == sorted(times)


def test_leads_malformed_cursor_rejected():
    h = Harness()
    for bad in ["garbage", "", "e30", "..%2F..%2Fetc%2Fpasswd", "a" * 600]:
        r = h.get(f"{BASE}/leads?cursor={bad}")
        assert r.status_code == 400, bad[:20]
        assert r.json()["error"]["code"] == "invalid_cursor"


def test_leads_time_range_bounded_to_90_days():
    h = Harness()
    assert h.get(f"{BASE}/leads?since=2026-08-17T16:00:00Z&until=2026-11-15T16:00:00Z").status_code == 200
    too_wide = h.get(f"{BASE}/leads?since=2026-08-17T15:59:59Z&until=2026-11-15T16:00:00Z")
    assert too_wide.status_code == 400 and too_wide.json()["error"]["code"] == "invalid_range"
    assert h.get(f"{BASE}/leads?since=2026-11-15T16:00:00Z&until=2026-11-14T16:00:00Z").status_code == 400
    garbage = h.get(f"{BASE}/leads?since=yesterday")
    assert garbage.status_code == 400 and garbage.json()["error"]["code"] == "invalid_time"
    narrow = h.get(f"{BASE}/leads?since=2026-11-15T13:30:00Z").json()
    assert [i["id"] for i in narrow["items"]] == ["evt_lead_002", "evt_signup_001", "evt_lead_001"]


def test_leads_outside_default_range_or_malformed_are_dropped():
    rows = [
        None,
        {"id": "evt_old", "kind": "lead", "occurred_at": "2026-01-01T00:00:00Z"},
        {"id": "has space", "kind": "lead", "occurred_at": "2026-11-15T12:00:00Z"},
        {"id": "evt_x", "kind": "password_reset", "occurred_at": "2026-11-15T12:00:00Z"},
        {"id": "evt_d", "kind": "deploy", "occurred_at": "2026-11-15T12:00:00Z"},
        {"id": "evt_y", "kind": "lead", "occurred_at": "not a date"},
        {"id": "evt_ok", "kind": "paid_conversion", "occurred_at": "2026-11-15T12:00:00Z", "source": "stripe", "value_cents": 4900, "customer_email": "a@b.com"},
    ]
    r = Harness(leads=lambda q: rows).get(f"{BASE}/leads")
    assert r.json()["items"] == [{"id": "evt_ok", "kind": "paid_conversion", "occurred_at": "2026-11-15T12:00:00Z", "source": "stripe", "title": "Paid conversion", "value_cents": 4900}]


def test_events_have_stable_ids():
    h = Harness()
    a = h.get(f"{BASE}/events?limit=100").json()
    b = h.get(f"{BASE}/events?limit=100").json()
    ids = [i["id"] for i in a["items"]]
    assert len(ids) == 22 and len(set(ids)) == 22
    assert ids == [i["id"] for i in b["items"]]
    assert a["items"][0]["kind"] == "deploy"


# ---------- signing ----------


def test_signing_required_once_secret_configured():
    h = Harness(signing_secret=SECRET)
    url = f"{BASE}/metrics?window=7d"
    unsigned = h.get(url)
    assert unsigned.status_code == 401 and unsigned.json()["error"]["code"] == "invalid_signature"
    assert h.get(url, headers=signed(url)).status_code == 200
    m = h.get(f"{BASE}/manifest", headers=signed(f"{BASE}/manifest"))
    assert m.json()["signing_required"] is True and SECRET not in m.text


def test_signature_does_not_replace_bearer_token():
    h = Harness(signing_secret=SECRET)
    r = h.get(f"{BASE}/status", token=None, headers=signed(f"{BASE}/status"))
    assert r.status_code == 401 and r.json()["error"]["code"] == "unauthorized"


def test_signing_replay_rejected():
    h = Harness(signing_secret=SECRET)
    url = f"{BASE}/status"
    headers = signed(url)
    assert h.get(url, headers=headers).status_code == 200
    replay = h.get(url, headers=headers)
    assert replay.status_code == 401 and replay.json()["error"]["code"] == "replayed_request"
    h.clock[0] = NOW + 120
    assert h.get(url, headers=headers).status_code == 401
    assert h.get(url, headers=signed(url, now=h.clock[0])).status_code == 200


def test_signing_rejects_stale_wrong_secret_and_other_paths():
    h = Harness(signing_secret=SECRET)
    url = f"{BASE}/metrics?window=24h"
    cases = [
        signed(url, now=NOW - 301),
        signed(url, now=NOW + 301),
        signed(url, secret="wrong-secret-0123456789abc"),
        signed(f"{BASE}/metrics?window=90d"),
        signed(f"{BASE}/leads"),
        signed(url, method="POST"),
        {"X-ForgeDeck-Timestamp": str(int(NOW))},
        {"X-ForgeDeck-Timestamp": "now", "X-ForgeDeck-Signature": "f" * 64},
    ]
    for headers in cases:
        r = h.get(url, headers=headers)
        assert r.status_code == 401
        assert r.json()["error"]["code"] == "invalid_signature"
    assert h.get(url, headers=signed(url, now=NOW - 299)).status_code == 200


# ---------- transport ----------


def test_https_required_for_non_loopback_clients():
    plain = Harness(client_addr=("203.0.113.7", 50000)).get(f"{BASE}/status")
    assert plain.status_code == 403
    assert plain.json()["error"]["code"] == "https_required"
    assert "release" not in plain.json()
    assert Harness(client_addr=("203.0.113.7", 50000), base_url="https://testserver").get(f"{BASE}/status").status_code == 200
    for addr in ["127.0.0.1", "::1"]:
        assert Harness(client_addr=(addr, 50000)).get(f"{BASE}/status").status_code == 200


def test_x_forwarded_proto_ignored_unless_trust_proxy():
    spoof = {"X-Forwarded-Proto": "https"}
    assert Harness(client_addr=("203.0.113.7", 50000)).get(f"{BASE}/status", headers=spoof).status_code == 403
    assert Harness(client_addr=("10.0.0.2", 50000), trust_proxy=True).get(f"{BASE}/status", headers=spoof).status_code == 200
    via_proxy_plain = Harness(client_addr=("127.0.0.1", 50000), trust_proxy=True).get(f"{BASE}/status", headers={"X-Forwarded-Proto": "http"})
    assert via_proxy_plain.status_code == 403


def test_require_https_can_be_disabled_explicitly():
    assert Harness(client_addr=("10.0.0.9", 50000), require_https=False).get(f"{BASE}/status").status_code == 200


# ---------- rate limiting ----------


def test_rate_limit_429_with_retry_after_and_reset():
    h = Harness(rate_limit=5, rate_window_seconds=60)
    for _ in range(5):
        assert h.get(f"{BASE}/status").status_code == 200
    h.clock[0] = NOW + 15
    limited = h.get(f"{BASE}/status")
    assert limited.status_code == 429
    assert limited.json()["error"]["code"] == "rate_limited"
    assert limited.headers["retry-after"] == "45"
    h.clock[0] = NOW + 60
    assert h.get(f"{BASE}/status").status_code == 200


def test_rate_limit_default_is_60_per_minute():
    h = Harness()
    for _ in range(60):
        assert h.get(f"{BASE}/manifest").status_code == 200
    assert h.get(f"{BASE}/manifest").status_code == 429


def test_rate_limit_is_per_token_and_failed_auth_per_address():
    other = "fdk_other_token_0123456789abcdefghi"
    h = Harness(rate_limit=3, tokens=[TokenRecord.from_plaintext("a", TOKEN, SCOPES), TokenRecord.from_plaintext("b", other, SCOPES)])
    for _ in range(3):
        h.get(f"{BASE}/status")
    assert h.get(f"{BASE}/status").status_code == 429
    assert h.get(f"{BASE}/status", token=other).status_code == 200
    for _ in range(3):
        assert h.get(f"{BASE}/status", token="guess-0000000000000000").status_code == 401
    assert h.get(f"{BASE}/status", token="guess-0000000000000000").status_code == 429


# ---------- logging ----------


def test_log_lines_never_contain_tokens_or_query_strings():
    h = Harness(signing_secret=SECRET)
    url = f"{BASE}/metrics?window=24h"
    headers = signed(url)
    h.get(url, headers=headers)
    leaky = f"{BASE}/status?token={TOKEN}&access_token={TOKEN}"
    h.get(leaky, headers=signed(leaky))
    h.get(f"{BASE}/status", token="wrong-token-zzzzzzzzzzzzzzzz")
    assert len(h.logs) == 3
    joined = "\n".join(h.logs)
    for needle in [TOKEN, hash_token(TOKEN), SECRET, headers["X-ForgeDeck-Signature"], "wrong-token", "window=", "Bearer"]:
        assert needle not in joined, needle
    assert h.logs[0].startswith("[forgedeck-companion] GET /_forgedeck/v1/metrics 200 token=main ")
    assert " 401 token=- " in h.logs[2]


# ---------- mounting ----------


def test_other_app_routes_are_untouched():
    h = Harness()
    r = h.client.get("/api/users")
    assert r.status_code == 200 and r.json() == {"ok": True}
    assert h.logs == []


def test_responses_are_json_serialisable_and_compact():
    r = Harness().get(f"{BASE}/events?limit=3")
    assert r.headers["content-type"].startswith("application/json")
    json.loads(r.text)
