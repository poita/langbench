"""HMAC-SHA-256 (RFC 2104), implemented from scratch on top of :mod:`.sha256`."""

from __future__ import annotations

from .sha256 import BLOCK_SIZE, sha256

__all__ = ["hmac_sha256"]

_IPAD = bytes([0x36] * BLOCK_SIZE)
_OPAD = bytes([0x5C] * BLOCK_SIZE)


def hmac_sha256(key: bytes, message: bytes) -> bytes:
    """Return the 32-byte HMAC-SHA-256 of *message* under *key*.

    Keys of any length are accepted, including the empty key.
    """
    key = bytes(key)
    if len(key) > BLOCK_SIZE:
        key = sha256(key)
    key = key.ljust(BLOCK_SIZE, b"\x00")
    inner_key = bytes(k ^ p for k, p in zip(key, _IPAD))
    outer_key = bytes(k ^ p for k, p in zip(key, _OPAD))
    return sha256(outer_key + sha256(inner_key + bytes(message)))
