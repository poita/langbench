"""Webhook signing secrets."""

from __future__ import annotations

from .b64 import Base64Error, b64decode

__all__ = ["InvalidSecret", "parse_secret", "SECRET_PREFIX"]

SECRET_PREFIX = "whsec_"


class InvalidSecret(ValueError):
    """Raised when a secret is not valid Base64 or decodes to no bytes."""


def parse_secret(secret: str | bytes) -> bytes:
    """Return the raw HMAC key for a ``whsec_``-style *secret*.

    A leading ``whsec_`` is removed once; the remainder is Base64-decoded
    (either alphabet, padding optional).  The key must be non-empty.
    """
    if isinstance(secret, bytes):
        secret = secret.decode("latin-1")
    if secret.startswith(SECRET_PREFIX):
        secret = secret[len(SECRET_PREFIX):]
    try:
        key = b64decode(secret)
    except Base64Error as exc:
        raise InvalidSecret(str(exc)) from None
    if not key:
        raise InvalidSecret("secret decodes to zero bytes")
    return key
