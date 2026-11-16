"""FastAPI router exposing the read-only ForgeDeck companion endpoints.

    from forgedeck_companion import CompanionConfig, TokenRecord, create_router

    app.include_router(create_router(CompanionConfig(
        product_id="example-product",
        environment="production",
        capabilities={"status", "metrics"},
        tokens=[TokenRecord(id="forgedeck", sha256=os.environ["FORGEDECK_TOKEN_SHA256"],
                            scopes={"status:read", "metrics:read"})],
        release=load_release_file("forgedeck-release.json"),
        metrics=my_metrics_function,
    )))

All routes are GET, default-deny, and never accept product/environment from the request.
"""

from __future__ import annotations

import inspect
import logging
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Set

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from . import core

IMPLEMENTATION = {"name": "forgedeck-companion-python", "version": "1.0.0"}
DEFAULT_PREFIX = "/_forgedeck/v1"

# capability None => available to any authenticated token holding the scope.
ROUTES: Dict[str, Dict[str, Optional[str]]] = {
    "manifest": {"scope": "status:read", "capability": None},
    "status": {"scope": "status:read", "capability": "status"},
    "metrics": {"scope": "metrics:read", "capability": "metrics"},
    "leads": {"scope": "leads:read", "capability": "leads"},
    "events": {"scope": "events:read", "capability": "events"},
}

_default_logger = logging.getLogger("forgedeck_companion")


@dataclass
class CompanionConfig:
    """Server-side configuration. ``product_id`` and ``environment`` are only ever read from here."""

    product_id: str
    environment: str
    component_id: str = "backend"
    component_ids: Optional[Sequence[str]] = None
    metadata: Mapping[str, Any] = field(default_factory=dict)
    #: Capabilities to serve. Empty by default: nothing but the manifest is reachable.
    capabilities: Iterable[str] = field(default_factory=set)
    #: Token records. Empty by default: every request is refused (503 not_configured).
    tokens: Sequence[core.TokenRecord] = field(default_factory=list)
    #: When set, every request must carry a valid HMAC signature.
    signing_secret: Optional[str] = None
    require_https: bool = True
    #: Opt in to honouring X-Forwarded-Proto from a reverse proxy you control.
    trust_proxy: bool = False
    rate_limit: int = 60
    rate_window_seconds: int = 60
    #: Add a masked label ("j***@e***.com") to /leads items. Off by default.
    leads_masked_label: bool = False
    metrics_allowed: Sequence[str] = core.DEFAULT_METRICS
    metrics_source: str = "application"
    #: Providers. Each may be sync or async.
    release: Any = None  # dict, or callable returning a dict
    health: Optional[Callable[[], Any]] = None  # -> {"checks": [{"id", "state"}]}
    metrics: Optional[Callable[[str, int], Any]] = None  # (window, seconds) -> {name: number}
    leads: Optional[Callable[[Dict[str, Any]], Any]] = None  # (query) -> [item dicts]
    events: Optional[Callable[[Dict[str, Any]], Any]] = None
    instances: Optional[Callable[[], Any]] = None  # -> [{"id", "commit_sha"}]
    booted_at: Optional[datetime] = None
    logger: Optional[Callable[[str], None]] = None
    #: Clock returning epoch seconds (overridable for tests).
    now: Callable[[], float] = time.time

    def __post_init__(self) -> None:
        if not isinstance(self.product_id, str) or not core.ID_RE.match(self.product_id):
            raise ValueError("product_id must match " + core.ID_RE.pattern)
        if self.environment not in core.ENVIRONMENTS:
            raise ValueError("environment must be one of: " + ", ".join(core.ENVIRONMENTS))
        if not core.ID_RE.match(self.component_id or ""):
            raise ValueError("component_id is invalid")
        ids = list(self.component_ids) if self.component_ids else [self.component_id]
        for c in ids:
            if not isinstance(c, str) or not core.ID_RE.match(c):
                raise ValueError(f"component_ids contains invalid id {c!r}")
        self.component_ids = ids
        if isinstance(self.capabilities, (str, bytes)) or isinstance(self.capabilities, Mapping):
            raise ValueError("capabilities must be a set/list of capability names")
        caps: Set[str] = set(self.capabilities)
        unknown = caps - set(core.CAPABILITIES)
        if unknown:
            raise ValueError(f"unknown capability: {', '.join(sorted(map(str, unknown)))}")
        self.capabilities = [c for c in core.CAPABILITIES if c in caps]
        self.tokens = list(self.tokens)
        seen: Set[str] = set()
        for t in self.tokens:
            if not isinstance(t, core.TokenRecord):
                raise ValueError("tokens must be TokenRecord instances")
            if t.id in seen:
                raise ValueError(f"duplicate token id {t.id!r}")
            seen.add(t.id)
        if self.signing_secret is not None and (not isinstance(self.signing_secret, str) or len(self.signing_secret) < 16):
            raise ValueError("signing_secret must be a string of at least 16 characters")
        self.metrics_allowed = list(self.metrics_allowed)
        for m in self.metrics_allowed:
            if not core.is_metric_name(m):
                raise ValueError(f"invalid metric name {m!r}")
        self.metrics_source = core.short_string(self.metrics_source, 64) or "application"
        safe_meta: Dict[str, str] = {}
        for k, v in list(dict(self.metadata).items())[:20]:
            s = core.short_string(v, 200)
            if core.is_metric_name(k) and s is not None:
                safe_meta[k] = s
        self.metadata = safe_meta
        if self.booted_at is None:
            self.booted_at = datetime.now(timezone.utc)


class _HttpError(Exception):
    def __init__(self, status: int, code: str, message: str, headers: Optional[Dict[str, str]] = None) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.headers = headers or {}


async def _call(fn: Any, *args: Any) -> Any:
    result = fn(*args)
    if inspect.isawaitable(result):
        result = await result
    return result


_RESPONSE_HEADERS = {"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"}


def _json(status: int, body: Dict[str, Any], headers: Optional[Dict[str, str]] = None) -> JSONResponse:
    return JSONResponse(body, status_code=status, headers={**_RESPONSE_HEADERS, **(headers or {})})


def create_router(config: CompanionConfig, prefix: str = DEFAULT_PREFIX) -> APIRouter:
    """Build the companion router. Mount with ``app.include_router(create_router(config))``."""
    cfg = config
    prefix = prefix.rstrip("/")
    limiter = core.RateLimiter(cfg.rate_limit, cfg.rate_window_seconds)
    nonces = core.NonceCache()
    router = APIRouter(prefix=prefix, include_in_schema=False)

    def is_secure(request: Request) -> bool:
        if cfg.trust_proxy:
            # Opt-in only: trusted because the operator says a proxy they control sets it.
            xfp = request.headers.get("x-forwarded-proto")
            if xfp:
                return xfp.split(",")[0].strip().lower() == "https"
        if request.url.scheme == "https":
            return True
        return core.is_loopback_address(request.client.host if request.client else None)

    def base_body(now: datetime) -> Dict[str, Any]:
        return {
            "schema_version": core.SCHEMA_VERSION,
            "product_id": cfg.product_id,
            "environment": cfg.environment,
            "observed_at": core.iso_seconds(now),
        }

    async def window_metrics(window: str) -> Dict[str, Any]:
        if cfg.metrics is None:
            return {}
        return core.sanitize_metrics(await _call(cfg.metrics, window, core.WINDOWS[window]), cfg.metrics_allowed)

    async def route_manifest(token: core.TokenRecord, now: datetime, request: Request) -> Dict[str, Any]:
        return {
            **base_body(now),
            "component_ids": list(cfg.component_ids or []),
            "capabilities": list(cfg.capabilities),
            "scopes": [s for s in core.SCOPES if s in token.scopes],
            "windows": list(core.WINDOWS),
            "signing_required": cfg.signing_secret is not None,
            "metadata": dict(cfg.metadata),
            "companion": dict(IMPLEMENTATION),
        }

    async def route_status(token: core.TokenRecord, now: datetime, request: Request) -> Dict[str, Any]:
        release = cfg.release
        if callable(release):
            release = await _call(release)
        try:
            health = core.normalize_health(await _call(cfg.health) if cfg.health else None)
        except Exception:  # noqa: BLE001 - a failing probe is reported, never leaked
            health = {"state": "unhealthy", "checks": [{"id": "health_provider", "state": "unhealthy"}]}
        metrics: Dict[str, Any] = {}
        if "metrics" in cfg.capabilities and core.has_scope(token, "metrics:read"):
            try:
                metrics = {f"{k}_24h": v for k, v in (await window_metrics("24h")).items()}
            except Exception:  # noqa: BLE001 - status is still served when metrics are down
                metrics = {}
        body: Dict[str, Any] = {
            "schema_version": core.SCHEMA_VERSION,
            "product_id": cfg.product_id,
            "component_id": cfg.component_id,
            "environment": cfg.environment,
            "observed_at": core.iso_seconds(now),
            "release": core.normalize_release(release),
            "health": health,
            "metrics": metrics,
            "capabilities": list(cfg.capabilities),
            "booted_at": core.iso_seconds(cfg.booted_at),  # type: ignore[arg-type]
        }
        if cfg.instances is not None:
            raw = await _call(cfg.instances)
            instances: List[Dict[str, Any]] = []
            for i in list(raw or [])[:100]:
                if not isinstance(i, dict) or not isinstance(i.get("id"), str) or not core._ITEM_ID_RE.match(i["id"]):
                    continue
                sha = i.get("commit_sha")
                instances.append({"id": i["id"], "commit_sha": sha.lower() if isinstance(sha, str) and core._SHA_RE.match(sha) else None})
            body["instances"] = instances
        return body

    async def route_metrics(token: core.TokenRecord, now: datetime, request: Request) -> Dict[str, Any]:
        window = request.query_params.get("window", "24h")
        if window not in core.WINDOWS:
            raise _HttpError(400, "invalid_window", "window must be one of: " + ", ".join(core.WINDOWS))
        return {**base_body(now), "window": window, "source": cfg.metrics_source, "metrics": await window_metrics(window)}

    def parse_list_params(request: Request, now: datetime) -> Dict[str, Any]:
        q = request.query_params
        limit = core.DEFAULT_LIMIT
        if "limit" in q:
            raw = q["limit"]
            if not (raw.isascii() and raw.isdigit() and len(raw) <= 4 and 1 <= int(raw) <= core.MAX_LIMIT):
                raise _HttpError(400, "invalid_limit", f"limit must be an integer between 1 and {core.MAX_LIMIT}")
            limit = int(raw)
        after = None
        if "cursor" in q:
            after = core.decode_cursor(q["cursor"])
            if after is None:
                raise _HttpError(400, "invalid_cursor", "cursor is not valid")

        def when(name: str) -> Optional[datetime]:
            if name not in q:
                return None
            parsed = core.parse_time(q[name])
            if parsed is None:
                raise _HttpError(400, "invalid_time", f"{name} must be an ISO-8601 timestamp such as 2026-11-15T16:00:00Z")
            return parsed

        until = when("until") or now
        since = when("since") or until - timedelta(seconds=core.MAX_RANGE_SECONDS)
        if since >= until:
            raise _HttpError(400, "invalid_range", "since must be earlier than until")
        if (until - since).total_seconds() > core.MAX_RANGE_SECONDS:
            raise _HttpError(400, "invalid_range", "time range must not exceed 90 days")
        return {"limit": limit, "after": after, "since": since, "until": until}

    async def route_list(provider: Any, kinds: Sequence[str], with_label: bool, now: datetime, request: Request) -> Dict[str, Any]:
        p = parse_list_params(request, now)
        limit, after, since, until = p["limit"], p["after"], p["since"], p["until"]
        raw: Any = []
        if provider is not None:
            raw = await _call(
                provider,
                {
                    "since": since,
                    "until": until,
                    "after": {"occurred_at": after[0], "id": after[1]} if after else None,
                    "limit": limit + 1,
                },
            )
        rows = []
        for r in list(raw or []):
            s = core.sanitize_item(r, kinds, with_label)
            if s is None:
                continue
            item, t = s
            if t < since.replace(microsecond=0) or t > until:
                continue
            if after and not (t > after[0] or (t == after[0] and item["id"] > after[1])):
                continue
            rows.append((t, item["id"], item))
        # Stable order: oldest first, id as tie-breaker. Cursors point at the last item returned.
        rows.sort(key=lambda row: (row[0], row[1]))
        page = rows[:limit]
        next_cursor = core.encode_cursor(page[-1][2]["occurred_at"], page[-1][1]) if len(rows) > limit and page else None
        return {**base_body(now), "items": [row[2] for row in page], "next_cursor": next_cursor}

    async def route_leads(token: core.TokenRecord, now: datetime, request: Request) -> Dict[str, Any]:
        return await route_list(cfg.leads, core.LEAD_KINDS, cfg.leads_masked_label, now, request)

    async def route_events(token: core.TokenRecord, now: datetime, request: Request) -> Dict[str, Any]:
        return await route_list(cfg.events, core.EVENT_KINDS, False, now, request)

    handlers = {"manifest": route_manifest, "status": route_status, "metrics": route_metrics, "leads": route_leads, "events": route_events}

    async def evaluate(request: Request, name: str, ctx: Dict[str, Any]) -> Dict[str, Any]:
        now_epoch = cfg.now()
        now = datetime.fromtimestamp(now_epoch, tz=timezone.utc)
        if request.method != "GET":
            raise _HttpError(405, "method_not_allowed", "Only GET is supported", {"Allow": "GET"})
        path_with_query = request.url.path + ("?" + request.url.query if request.url.query else "")
        if len(path_with_query) > 2048:
            raise _HttpError(400, "invalid_request", "Request target too long")
        # Default deny: without at least one configured token nothing is served.
        if not cfg.tokens:
            raise _HttpError(503, "not_configured", "Companion is not configured")
        if cfg.require_https and not is_secure(request):
            raise _HttpError(403, "https_required", "HTTPS is required")

        remote = request.client.host if request.client else "unknown"
        check = core.verify_token(core.extract_bearer(request.headers.get("authorization")), cfg.tokens, now)
        if not check.ok:
            allowed, retry = limiter.hit(f"addr:{remote}", now_epoch)
            if not allowed:
                raise _HttpError(429, "rate_limited", "Too many requests", {"Retry-After": str(retry)})
            raise _HttpError(401, "unauthorized", "Missing or invalid bearer token", {"WWW-Authenticate": "Bearer"})
        token = check.record
        assert token is not None
        ctx["token_id"] = token.id

        allowed, retry = limiter.hit(f"token:{token.id}", now_epoch)
        if not allowed:
            raise _HttpError(429, "rate_limited", "Too many requests", {"Retry-After": str(retry)})

        if cfg.signing_secret is not None:
            timestamp = request.headers.get("x-forgedeck-timestamp")
            signature = request.headers.get("x-forgedeck-signature")
            ok, _reason = core.verify_signature(cfg.signing_secret, timestamp, signature, request.method, path_with_query, int(now_epoch))
            if not ok:
                raise _HttpError(401, "invalid_signature", "Missing, invalid or stale request signature")
            assert timestamp is not None and signature is not None
            if not nonces.check_and_store(f"{timestamp}:{signature.lower()}", int(now_epoch), core.MAX_SKEW_SECONDS * 2 + 1):
                raise _HttpError(401, "replayed_request", "Request signature was already used")

        route = ROUTES.get(name)
        # Unknown routes and disabled capabilities are indistinguishable.
        if route is None or (route["capability"] and route["capability"] not in cfg.capabilities):
            raise _HttpError(404, "not_found", "Not found")
        if not core.has_scope(token, route["scope"] or ""):
            raise _HttpError(403, "insufficient_scope", f"Token lacks scope {route['scope']}")
        return await handlers[name](token, now, request)

    async def handle(request: Request, name: str) -> JSONResponse:
        started = time.monotonic()
        ctx: Dict[str, Any] = {"token_id": None}
        try:
            response = _json(200, await evaluate(request, name, ctx))
        except _HttpError as err:
            response = _json(err.status, {"schema_version": core.SCHEMA_VERSION, "error": {"code": err.code, "message": err.message}}, err.headers)
        except Exception:  # noqa: BLE001 - never leak provider errors to the client
            response = _json(500, {"schema_version": core.SCHEMA_VERSION, "error": {"code": "internal_error", "message": "Internal error"}})
        # Log line: method, path WITHOUT query string, status, token id. Never the token or headers.
        safe_path = "".join(ch if "!" <= ch <= "~" else "?" for ch in request.url.path[:200])
        line = f"[forgedeck-companion] {request.method[:10]} {safe_path} {response.status_code} token={ctx['token_id'] or '-'} {int((time.monotonic() - started) * 1000)}ms"
        try:
            (cfg.logger or _default_logger.info)(line)
        except Exception:  # noqa: BLE001 - a broken logger must not break the response
            pass
        return response

    all_methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    def _make(name: str) -> Callable[[Request], Any]:
        async def endpoint(request: Request) -> JSONResponse:
            return await handle(request, name)

        endpoint.__name__ = f"forgedeck_{name}"
        return endpoint

    for route_name in ROUTES:
        router.add_api_route(f"/{route_name}", _make(route_name), methods=all_methods)

    async def fallback(request: Request, rest: str = "") -> JSONResponse:
        return await handle(request, "\x00unknown")

    # Anything else under the prefix gets the same gate (401/404/405), never a framework default.
    router.add_api_route("", fallback, methods=all_methods)
    router.add_api_route("/{rest:path}", fallback, methods=all_methods)
    return router
