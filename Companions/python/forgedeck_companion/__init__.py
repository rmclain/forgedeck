"""ForgeDeck companion: read-only status/metrics/leads/events endpoints for FastAPI apps."""

from .core import (
    CAPABILITIES,
    ENVIRONMENTS,
    SCHEMA_VERSION,
    SCOPES,
    WINDOWS,
    TokenRecord,
    generate_token,
    hash_token,
    load_release_file,
    mask_email,
    sign_request,
)

__version__ = "1.0.0"

__all__ = [
    "CAPABILITIES",
    "ENVIRONMENTS",
    "SCHEMA_VERSION",
    "SCOPES",
    "WINDOWS",
    "CompanionConfig",
    "TokenRecord",
    "create_router",
    "generate_token",
    "hash_token",
    "load_release_file",
    "mask_email",
    "sign_request",
]


def __getattr__(name):
    # Lazy so that `forgedeck_companion.core` stays importable without FastAPI installed.
    if name in ("CompanionConfig", "create_router"):
        from . import router

        return getattr(router, name)
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
