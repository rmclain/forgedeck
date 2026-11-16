"""Unit tests for the framework-free helpers (no FastAPI needed)."""

import base64
from datetime import datetime, timedelta, timezone

import pytest

from forgedeck_companion import core

NOW = datetime(2026, 11, 15, 16, 0, 0, tzinfo=timezone.utc)


def test_hash_token_is_sha256_hex_and_tokens_are_random():
    assert core.hash_token("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    a, b = core.generate_token(), core.generate_token()
    assert a.startswith("fdk_") and len(a) >= 40 and a != b


def test_token_record_keeps_only_the_hash():
    rec = core.TokenRecord.from_plaintext("a", "plaintext-token-123456", ["status:read"])
    assert rec.sha256 == core.hash_token("plaintext-token-123456")
    assert "plaintext-token-123456" not in repr(rec)


def test_token_record_validation():
    with pytest.raises(ValueError):
        core.TokenRecord(id="a", sha256="nothex")
    with pytest.raises(ValueError):
        core.TokenRecord.from_plaintext("a", "short", [])
    with pytest.raises(ValueError):
        core.TokenRecord.from_plaintext("a", "long-enough-token-1234", ["admin:write"])
    with pytest.raises(ValueError):
        core.TokenRecord.from_plaintext("bad id!", "long-enough-token-1234", [])


def test_extract_bearer():
    assert core.extract_bearer("Bearer abc.DEF-123_x") == "abc.DEF-123_x"
    for bad in ["bearer abc", "Basic abc", "Bearer ", "Bearer a b", None, "Bearer " + "a" * 2000]:
        assert core.extract_bearer(bad) is None


def test_verify_token_ok_unknown_revoked_expired():
    records = [
        core.TokenRecord.from_plaintext("good", "good-token-0123456789", ["status:read"]),
        core.TokenRecord.from_plaintext("revoked", "revoked-token-0123456789", ["status:read"], revoked=True),
        core.TokenRecord.from_plaintext("expired", "expired-token-0123456789", ["status:read"], expires_at=NOW - timedelta(seconds=1)),
        core.TokenRecord.from_plaintext("future", "future-token-0123456789", ["status:read"], expires_at=NOW + timedelta(days=1)),
    ]
    assert core.verify_token("good-token-0123456789", records, NOW).ok
    assert core.verify_token("future-token-0123456789", records, NOW).ok
    assert core.verify_token("nope-token-0123456789", records, NOW).reason == "unknown"
    assert core.verify_token("revoked-token-0123456789", records, NOW).reason == "revoked"
    assert core.verify_token("expired-token-0123456789", records, NOW).reason == "expired"
    assert core.verify_token(None, records, NOW).reason == "missing"
    assert core.verify_token("", records, NOW).reason == "missing"
    # Presenting the stored hash instead of the token must not authenticate.
    assert not core.verify_token(records[0].sha256, records, NOW).ok


def test_has_scope():
    rec = core.TokenRecord.from_plaintext("a", "good-token-0123456789", ["status:read"])
    assert core.has_scope(rec, "status:read")
    assert not core.has_scope(rec, "leads:read")
    assert not core.has_scope(None, "status:read")


def test_signature_matches_documented_vector_and_rejects_tampering():
    secret = "signing-secret-0123456789"
    now = 1794758400
    path = "/_forgedeck/v1/metrics?window=24h"
    assert core.canonical_string("1794758400", "get", path) == "1794758400\nGET\n/_forgedeck/v1/metrics?window=24h"
    sig = core.sign_request(secret, str(now), "GET", path)
    # Same vector as contract/README.md and the Node/PHP test suites.
    assert sig == "8e06b08e0d1b608b4be2b998316ad034375c056a8b375707af02dfe86f31a01b"
    assert core.verify_signature(secret, str(now), sig, "GET", path, now) == (True, "")
    assert core.verify_signature(secret, str(now), sig.upper(), "GET", path, now)[0]
    assert core.verify_signature(secret, str(now), sig, "GET", path, now + 300)[0]
    assert core.verify_signature(secret, str(now), sig, "GET", path, now + 301) == (False, "stale_timestamp")
    assert core.verify_signature(secret, str(now), sig, "GET", path, now - 301) == (False, "stale_timestamp")
    assert core.verify_signature(secret, str(now), sig, "GET", path.replace("24h", "7d"), now) == (False, "bad_signature")
    assert core.verify_signature(secret, str(now), sig, "POST", path, now) == (False, "bad_signature")
    assert core.verify_signature("another-secret-0123456789", str(now), sig, "GET", path, now) == (False, "bad_signature")
    assert core.verify_signature(secret, str(now), "zz", "GET", path, now) == (False, "bad_signature")
    assert core.verify_signature(secret, str(now), None, "GET", path, now) == (False, "bad_signature")
    assert core.verify_signature(secret, "abc", sig, "GET", path, now) == (False, "bad_timestamp")
    assert core.verify_signature(secret, None, sig, "GET", path, now) == (False, "bad_timestamp")


def test_nonce_cache_rejects_replays_and_stays_bounded():
    c = core.NonceCache(3)
    assert c.check_and_store("a", 100, 600)
    assert not c.check_and_store("a", 101, 600)
    assert c.check_and_store("a", 701, 600)
    for k in "bcde":
        c.check_and_store(k, 702, 600)
    assert len(c) <= 3


def test_rate_limiter():
    rl = core.RateLimiter(limit=3, window_seconds=60)
    t0 = 1_000_000.0
    assert rl.hit("k", t0) == (True, 0)
    assert rl.hit("k", t0 + 1)[0]
    assert rl.hit("k", t0 + 2)[0]
    assert rl.hit("k", t0 + 20) == (False, 40)
    assert rl.hit("other", t0 + 20)[0]
    assert rl.hit("k", t0 + 60)[0]


def test_cursor_round_trip_and_garbage():
    c = core.encode_cursor("2026-11-15T15:00:00Z", "evt_lead_001")
    assert core.decode_cursor(c) == (datetime(2026, 11, 15, 15, 0, tzinfo=timezone.utc), "evt_lead_001")
    b64 = lambda s: base64.urlsafe_b64encode(s.encode()).decode().rstrip("=")  # noqa: E731
    for bad in ["", "not base64!!", "e30", b64('{"v":1,"t":"nope","id":"x"}'), b64('{"v":2,"t":"2026-11-15T15:00:00Z","id":"x"}'), "a" * 600, None, 42]:
        assert core.decode_cursor(bad) is None


def test_cursor_is_interoperable_with_node_encoding():
    # base64url(JSON.stringify({v:1,t:"2026-11-15T15:00:00Z",id:"evt_lead_001"})) from the Node package.
    node_cursor = "eyJ2IjoxLCJ0IjoiMjAyNi0xMS0xNVQxNTowMDowMFoiLCJpZCI6ImV2dF9sZWFkXzAwMSJ9"
    assert core.encode_cursor("2026-11-15T15:00:00Z", "evt_lead_001") == node_cursor


def test_mask_email():
    assert core.mask_email("john@example.com") == "j***@e***.com"
    assert core.mask_email("Ann.Smith@Mail.Example.co.uk") == "a***@m***.uk"
    for bad in ["not-an-email", "a@b", None, 5]:
        assert core.mask_email(bad) is None


def test_parse_time_is_strict():
    assert core.parse_time("2026-11-15T16:00:00Z") == NOW
    assert core.parse_time("2026-11-15T17:00:00+01:00") == NOW
    assert core.parse_time("2026-11-15T16:00:00.123Z") == NOW.replace(microsecond=123000)
    for bad in ["yesterday", "2026-11-15", "2026-11-15 16:00:00", "2026-13-45T99:00:00Z", "", None, True]:
        assert core.parse_time(bad) is None
    assert core.iso_seconds(NOW.replace(microsecond=5)) == "2026-11-15T16:00:00Z"


def test_sanitize_item_whitelists_fields():
    raw = {"id": "evt_1", "kind": "lead", "occurred_at": "2026-11-15T12:00:00.500Z", "source": "contact_form", "email": "john@example.com", "name": "John", "phone": "555", "value_cents": 12.5}
    item, when = core.sanitize_item(raw, core.LEAD_KINDS, False)
    assert item == {"id": "evt_1", "kind": "lead", "occurred_at": "2026-11-15T12:00:00Z", "source": "contact_form", "title": "New lead", "value_cents": None}
    assert when == datetime(2026, 11, 15, 12, 0, tzinfo=timezone.utc)
    labelled, _ = core.sanitize_item(raw, core.LEAD_KINDS, True)
    assert labelled["label"] == "j***@e***.com"
    assert core.sanitize_item({**raw, "kind": "deploy"}, core.LEAD_KINDS, False) is None
    assert core.sanitize_item({**raw, "id": "has space"}, core.LEAD_KINDS, False) is None
    assert core.sanitize_item({**raw, "occurred_at": "nope"}, core.LEAD_KINDS, False) is None
    assert core.sanitize_item(None, core.LEAD_KINDS, False) is None


def test_sanitize_metrics_and_health_and_release():
    assert core.sanitize_metrics({"leads": 12, "signups": 9, "secret": 1, "x": "y"}, ["leads", "signups", "x"]) == {"leads": 12, "signups": 9}
    assert core.sanitize_metrics({"leads": True, "signups": float("nan")}, ["leads", "signups"]) == {}
    assert core.normalize_health(None) == {"state": "healthy", "checks": []}
    h = core.normalize_health({"checks": [{"id": "database", "state": "healthy", "error": "secret dsn"}, {"id": "queue", "state": "degraded"}, {"id": "x", "state": "??"}]})
    assert h == {"state": "unhealthy", "checks": [{"id": "database", "state": "healthy"}, {"id": "queue", "state": "degraded"}, {"id": "x", "state": "unhealthy"}]}
    assert core.normalize_release(None) == {"commit_sha": None, "version": None, "deployed_at": None}
    r = core.normalize_release({"commit_sha": "ABCDEF1", "version": "1.2.3", "built_at": "2026-11-14T12:00:00Z", "build_id": "42", "extra": "x"})
    assert r == {"commit_sha": "abcdef1", "version": "1.2.3", "deployed_at": "2026-11-14T12:00:00Z", "build_id": "42", "built_at": "2026-11-14T12:00:00Z"}


def test_load_release_file(tmp_path):
    p = tmp_path / "forgedeck-release.json"
    p.write_text('{"commit_sha": "0123456789abcdef0123456789abcdef01234567", "version": "1.8.2", "build_id": "9001", "built_at": "2026-11-14T12:00:00Z"}')
    assert core.load_release_file(str(p))["commit_sha"] == "0123456789abcdef0123456789abcdef01234567"
    assert core.load_release_file(str(tmp_path / "missing.json")) is None
    p.write_text("not json")
    assert core.load_release_file(str(p)) is None


def test_is_loopback_address():
    for a in ["127.0.0.1", "127.1.2.3", "::1", "::ffff:127.0.0.1"]:
        assert core.is_loopback_address(a)
    for a in ["10.0.0.1", "203.0.113.5", "testclient", "1127.0.0.1", "", None]:
        assert not core.is_loopback_address(a)
