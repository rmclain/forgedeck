"""Framework-free security and data helpers for the ForgeDeck companion.

Everything here uses the Python standard library only, so it can be unit-tested
(and reused with other frameworks) without FastAPI.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
import secrets
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

SCHEMA_VERSION = "1.0"
SCOPES = ("status:read", "metrics:read", "leads:read", "events:read")
CAPABILITIES = ("status", "metrics", "leads", "events")
ENVIRONMENTS = ("production", "staging", "development", "preview", "test")
WINDOWS: Dict[str, int] = {"24h": 86400, "7d": 604800, "30d": 2592000, "90d": 7776000}
MAX_RANGE_SECONDS = WINDOWS["90d"]
MAX_SKEW_SECONDS = 300
DEFAULT_LIMIT = 50
MAX_LIMIT = 100
LEAD_KINDS = ("lead", "signup", "paid_conversion", "renewal", "cancellation")
EVENT_KINDS = LEAD_KINDS + ("deploy", "incident")
HEALTH_STATES = ("healthy", "degraded", "unhealthy")
DEFAULT_METRICS = ("leads", "signups", "paid_conversions", "renewals", "cancellations")
DEFAULT_TITLES = {
    "lead": "New lead",
    "signup": "New signup",
    "paid_conversion": "Paid conversion",
    "renewal": "Renewal",
    "cancellation": "Cancellation",
    "deploy": "Deploy",
    "incident": "Incident",
}

ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,62}$")
_HASH_RE = re.compile(r"^[0-9a-f]{64}$")
_SHA_RE = re.compile(r"^[0-9a-fA-F]{7,40}$")
_BEARER_RE = re.compile(r"^Bearer ([A-Za-z0-9._~+/-]{1,512}={0,2})$")
_ITEM_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,128}$")
_SOURCE_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
_METRIC_RE = re.compile(r"^[a-z][a-z0-9_]{0,47}$")
_ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$")
_EMAIL_RE = re.compile(r"^([^@\s]+)@([^@\s.]+)((?:\.[^@\s.]+)*)\.([^@\s.]+)$")
_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")


# --------------------------------------------------------------------------- tokens


def hash_token(token: str) -> str:
    """SHA-256 hex digest of a bearer token. Only this digest is stored server-side."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def generate_token() -> str:
    """Create a new random bearer token (256 bits). Show it once; store hash_token(token)."""
    return "fdk_" + secrets.token_urlsafe(32)


@dataclass(frozen=True)
class TokenRecord:
    """A stored token: id, SHA-256 hash, scopes, optional expiry, revoked flag."""

    id: str
    sha256: str
    scopes: frozenset = frozenset()
    expires_at: Optional[datetime] = None
    revoked: bool = False

    def __post_init__(self) -> None:
        if not re.match(r"^[A-Za-z0-9_.-]{1,64}$", self.id or ""):
            raise ValueError("token id is invalid")
        object.__setattr__(self, "sha256", str(self.sha256).lower())
        if not _HASH_RE.match(self.sha256):
            raise ValueError("token sha256 must be 64 hex characters")
        scopes = frozenset(self.scopes)
        unknown = scopes - set(SCOPES)
        if unknown:
            raise ValueError(f"unknown scope(s): {', '.join(sorted(unknown))}")
        object.__setattr__(self, "scopes", scopes)
        if self.expires_at is not None:
            if not isinstance(self.expires_at, datetime):
                raise ValueError("expires_at must be a datetime")
            if self.expires_at.tzinfo is None:
                object.__setattr__(self, "expires_at", self.expires_at.replace(tzinfo=timezone.utc))

    @classmethod
    def from_plaintext(
        cls,
        id: str,
        token: str,
        scopes: Iterable[str],
        expires_at: Optional[datetime] = None,
        revoked: bool = False,
    ) -> "TokenRecord":
        """Convenience for tests/dev: hashes immediately; the plaintext is not retained."""
        if not isinstance(token, str) or len(token) < 16:
            raise ValueError("token is too short (min 16 chars)")
        return cls(id=id, sha256=hash_token(token), scopes=frozenset(scopes), expires_at=expires_at, revoked=revoked)


def extract_bearer(header: Optional[str]) -> Optional[str]:
    """Return the token from an ``Authorization: Bearer <token>`` header value, else None."""
    if not isinstance(header, str) or len(header) > 600:
        return None
    m = _BEARER_RE.match(header.strip())
    return m.group(1) if m else None


@dataclass(frozen=True)
class TokenCheck:
    ok: bool
    reason: str = ""
    record: Optional[TokenRecord] = None


def verify_token(presented: Optional[str], records: Sequence[TokenRecord], now: datetime) -> TokenCheck:
    """Compare the presented token's digest with every record in constant time (no early exit)."""
    if not isinstance(presented, str) or not presented:
        return TokenCheck(False, "missing")
    digest = hash_token(presented)
    match: Optional[TokenRecord] = None
    for rec in records:
        if hmac.compare_digest(digest, rec.sha256) and match is None:
            match = rec
    if match is None:
        return TokenCheck(False, "unknown")
    if match.revoked:
        return TokenCheck(False, "revoked", match)
    if match.expires_at is not None and now >= match.expires_at:
        return TokenCheck(False, "expired", match)
    return TokenCheck(True, "", match)


def has_scope(record: Optional[TokenRecord], scope: str) -> bool:
    return record is not None and scope in record.scopes


# --------------------------------------------------------------------------- signing


def canonical_string(timestamp: str, method: str, path_with_query: str) -> str:
    """The signed string: ``<timestamp>\\n<METHOD>\\n<path-with-query>``."""
    return f"{timestamp}\n{method.upper()}\n{path_with_query}"


def sign_request(secret: str, timestamp: str, method: str, path_with_query: str) -> str:
    """Hex HMAC-SHA256 signature for a request (client side / tests)."""
    msg = canonical_string(timestamp, method, path_with_query).encode("utf-8")
    return hmac.new(secret.encode("utf-8"), msg, hashlib.sha256).hexdigest()


def verify_signature(
    secret: str,
    timestamp: Optional[str],
    signature: Optional[str],
    method: str,
    path_with_query: str,
    now_seconds: int,
    max_skew_seconds: int = MAX_SKEW_SECONDS,
) -> Tuple[bool, str]:
    if not isinstance(timestamp, str) or not re.match(r"^[0-9]{1,12}$", timestamp):
        return False, "bad_timestamp"
    if not isinstance(signature, str) or not re.match(r"^[0-9a-fA-F]{64}$", signature):
        return False, "bad_signature"
    if abs(now_seconds - int(timestamp)) > max_skew_seconds:
        return False, "stale_timestamp"
    expected = sign_request(secret, timestamp, method, path_with_query)
    if not hmac.compare_digest(expected, signature.lower()):
        return False, "bad_signature"
    return True, ""


class NonceCache:
    """Small bounded cache of already-seen (timestamp, signature) pairs."""

    def __init__(self, max_entries: int = 5000) -> None:
        self.max = max_entries
        self._seen: Dict[str, int] = {}

    def check_and_store(self, key: str, now_seconds: int, ttl_seconds: int) -> bool:
        """True if the key is fresh (and is now recorded); False if it is a replay."""
        exp = self._seen.get(key)
        if exp is not None and exp > now_seconds:
            return False
        if len(self._seen) >= self.max:
            self._prune(now_seconds)
        self._seen[key] = now_seconds + ttl_seconds
        return True

    def _prune(self, now_seconds: int) -> None:
        for k in [k for k, exp in self._seen.items() if exp <= now_seconds]:
            del self._seen[k]
        while len(self._seen) >= self.max:
            del self._seen[next(iter(self._seen))]

    def __len__(self) -> int:
        return len(self._seen)


class RateLimiter:
    """Fixed-window limiter keyed by token id (or client address for failed auth)."""

    def __init__(self, limit: int = 60, window_seconds: int = 60, max_keys: int = 10000) -> None:
        self.limit = limit
        self.window = window_seconds
        self.max_keys = max_keys
        self._buckets: Dict[str, List[float]] = {}

    def hit(self, key: str, now: float) -> Tuple[bool, int]:
        """Returns (allowed, retry_after_seconds)."""
        b = self._buckets.get(key)
        if b is None or now - b[0] >= self.window:
            if len(self._buckets) >= self.max_keys:
                self._prune(now)
            b = [now, 0]
            self._buckets[key] = b
        b[1] += 1
        if b[1] > self.limit:
            remaining = b[0] + self.window - now
            return False, max(1, int(-(-remaining // 1)))
        return True, 0

    def _prune(self, now: float) -> None:
        for k in [k for k, b in self._buckets.items() if now - b[0] >= self.window]:
            del self._buckets[k]
        while len(self._buckets) >= self.max_keys:
            del self._buckets[next(iter(self._buckets))]


# --------------------------------------------------------------------------- time, cursors


def iso_seconds(dt: datetime) -> str:
    """UTC ISO-8601 with second precision and a Z suffix: 2026-11-15T16:00:00Z."""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_time(value: Any) -> Optional[datetime]:
    """Parse a datetime, epoch seconds or strict ISO-8601 string into an aware UTC datetime."""
    if isinstance(value, datetime):
        dt = value
    elif isinstance(value, bool):
        return None
    elif isinstance(value, (int, float)):
        try:
            dt = datetime.fromtimestamp(value, tz=timezone.utc)
        except (OverflowError, OSError, ValueError):
            return None
    elif isinstance(value, str) and _ISO_RE.match(value):
        text = value[:-1] + "+00:00" if value.endswith("Z") else value
        # Python < 3.11 only accepts 3 or 6 fractional digits; normalise to microseconds.
        m = re.match(r"^(.*T\d{2}:\d{2}:\d{2})(\.\d+)?([+-]\d{2}:\d{2})$", text)
        if m and m.group(2):
            text = m.group(1) + "." + (m.group(2)[1:] + "000000")[:6] + m.group(3)
        try:
            dt = datetime.fromisoformat(text)
        except ValueError:
            return None
    else:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def encode_cursor(occurred_at: str, item_id: str) -> str:
    """Opaque cursor: base64url(JSON {v, t, id}) of the last item returned."""
    raw = json.dumps({"v": 1, "t": occurred_at, "id": item_id}, separators=(",", ":")).encode("utf-8")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def decode_cursor(cursor: Any) -> Optional[Tuple[datetime, str]]:
    if not isinstance(cursor, str) or not cursor or len(cursor) > 512:
        return None
    if not re.match(r"^[A-Za-z0-9_-]+$", cursor):
        return None
    try:
        obj = json.loads(base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4)).decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    if not isinstance(obj, dict) or obj.get("v") != 1:
        return None
    item_id, t = obj.get("id"), obj.get("t")
    if not isinstance(item_id, str) or not item_id or len(item_id) > 128:
        return None
    if not isinstance(t, str) or len(t) > 40:
        return None
    when = parse_time(t)
    if when is None:
        return None
    return when, item_id


# --------------------------------------------------------------------------- redaction


def mask_email(email: Any) -> Optional[str]:
    """``john@example.com`` -> ``j***@e***.com``; None when the input is not email-shaped."""
    if not isinstance(email, str):
        return None
    m = _EMAIL_RE.match(email.strip())
    if not m:
        return None
    return f"{m.group(1)[0]}***@{m.group(2)[0]}***.{m.group(4)}".lower()


def short_string(value: Any, max_len: int) -> Optional[str]:
    if isinstance(value, bool) or not isinstance(value, (str, int, float)):
        return None
    s = _CONTROL_RE.sub(" ", str(value)).strip()
    return s[:max_len] if s else None


def normalize_release(raw: Any) -> Dict[str, Any]:
    r = raw if isinstance(raw, dict) else {}
    sha = r.get("commit_sha")
    deployed = parse_time(r.get("deployed_at"))
    built = parse_time(r.get("built_at"))
    out: Dict[str, Any] = {
        "commit_sha": sha.lower() if isinstance(sha, str) and _SHA_RE.match(sha) else None,
        "version": short_string(r.get("version"), 64),
        "deployed_at": iso_seconds(deployed) if deployed else None,
    }
    build_id = short_string(r.get("build_id"), 128)
    if build_id:
        out["build_id"] = build_id
    if built:
        out["built_at"] = iso_seconds(built)
        if out["deployed_at"] is None:
            out["deployed_at"] = out["built_at"]
    return out


def load_release_file(path: str) -> Optional[Dict[str, Any]]:
    """Read a CI-generated ``forgedeck-release.json``; None if missing or invalid."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            parsed = json.load(fh)
    except (OSError, ValueError):
        return None
    return normalize_release(parsed) if isinstance(parsed, dict) else None


def normalize_health(raw: Any) -> Dict[str, Any]:
    """Only ``id`` and ``state`` of each check are exposed; overall state is the worst one."""
    checks: List[Dict[str, str]] = []
    states: List[str] = []
    if isinstance(raw, dict):
        for c in list(raw.get("checks") or [])[:50]:
            if not isinstance(c, dict):
                continue
            cid = c.get("id")
            if not isinstance(cid, str) or not re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$", cid):
                continue
            state = c.get("state") if c.get("state") in HEALTH_STATES else "unhealthy"
            checks.append({"id": cid, "state": state})
            states.append(state)
        if raw.get("state") in HEALTH_STATES:
            states.append(raw["state"])
    worst = max((HEALTH_STATES.index(s) for s in states), default=0)
    return {"state": HEALTH_STATES[worst], "checks": checks}


def sanitize_metrics(raw: Any, allowed: Iterable[str]) -> Dict[str, Any]:
    out: Dict[str, Any] = {}
    if not isinstance(raw, dict):
        return out
    for key in allowed:
        v = raw.get(key)
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            continue
        if isinstance(v, float) and (v != v or v in (float("inf"), float("-inf"))):
            continue
        out[key] = v
    return out


def is_metric_name(name: Any) -> bool:
    return isinstance(name, str) and bool(_METRIC_RE.match(name))


def sanitize_item(raw: Any, kinds: Sequence[str], masked_label: bool) -> Optional[Tuple[Dict[str, Any], datetime]]:
    """Whitelist the fields of a lead/event item. Nothing outside this list is ever emitted."""
    if not isinstance(raw, dict):
        return None
    item_id = raw.get("id")
    if not isinstance(item_id, str) or not _ITEM_ID_RE.match(item_id):
        return None
    kind = raw.get("kind")
    if kind not in kinds:
        return None
    when = parse_time(raw.get("occurred_at"))
    if when is None:
        return None
    when = when.replace(microsecond=0)
    source = raw.get("source")
    value = raw.get("value_cents")
    item: Dict[str, Any] = {
        "id": item_id,
        "kind": kind,
        "occurred_at": iso_seconds(when),
        "source": source if isinstance(source, str) and _SOURCE_RE.match(source) else "unknown",
        "title": short_string(raw.get("title"), 120) or DEFAULT_TITLES[kind],
        "value_cents": value if isinstance(value, int) and not isinstance(value, bool) else None,
    }
    if masked_label:
        label = mask_email(raw.get("email"))
        if label:
            item["label"] = label
    return item, when


def is_loopback_address(addr: Any) -> bool:
    if not isinstance(addr, str):
        return False
    a = addr[7:] if addr.startswith("::ffff:") else addr
    return a == "::1" or bool(re.match(r"^127(\.\d{1,3}){3}$", a))
