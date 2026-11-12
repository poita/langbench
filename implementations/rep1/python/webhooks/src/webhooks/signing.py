"""Standard Webhooks signing."""

from __future__ import annotations

from collections.abc import Sequence

from .b64 import b64encode
from .hmac_sha256 import hmac_sha256
from .timestamp import is_canonical_int

__all__ = ["signed_content", "compute_mac", "sign_one", "sign"]

VERSION = "v1"


def _as_bytes(value: str | bytes | int) -> bytes:
    if isinstance(value, bytes):
        return value
    return str(value).encode("utf-8")


def signed_content(msg_id: str | bytes, timestamp: str | bytes | int, body: bytes) -> bytes:
    """Return ``id "." timestamp "." body``, the byte string that is signed."""
    return _as_bytes(msg_id) + b"." + _as_bytes(timestamp) + b"." + bytes(body)


def compute_mac(key: bytes, content: bytes) -> bytes:
    """HMAC-SHA-256 of already-assembled signed *content*."""
    return hmac_sha256(key, content)


def sign_one(key: bytes, msg_id: str | bytes, timestamp: str | bytes | int, body: bytes) -> str:
    """Return one ``v1,<base64>`` signature."""
    return f"{VERSION},{b64encode(compute_mac(key, signed_content(msg_id, timestamp, body)))}"


def sign(
    keys: Sequence[bytes],
    msg_id: str | bytes,
    timestamp: str | bytes | int,
    body: bytes,
) -> str:
    """Return the ``webhook-signature`` header value for *keys* (raw keys).

    One signature per key, in order, joined by single spaces.  *timestamp*
    must be a canonical decimal integer (an ``int`` or its text).
    """
    if not is_canonical_int(_as_bytes(timestamp)):
        raise ValueError("timestamp is not a canonical decimal integer")
    content = signed_content(msg_id, timestamp, body)
    return " ".join(f"{VERSION},{b64encode(compute_mac(k, content))}" for k in keys)
