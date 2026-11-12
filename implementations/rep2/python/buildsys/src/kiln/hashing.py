"""64-bit FNV-1a content hashing."""

from __future__ import annotations

__all__ = ["fnv1a64", "hash_hex", "format_hash"]

_OFFSET = 0xCBF29CE484222325
_PRIME = 0x100000001B3
_MASK = 0xFFFFFFFFFFFFFFFF

# Identical contents are hashed once.  The memo is bounded so that a long
# session cannot keep every historical file alive.
_MEMO: dict[bytes, bytes] = {}
_MEMO_LIMIT_BYTES = 64 * 1024 * 1024
_memo_bytes = 0


def fnv1a64(data: bytes) -> int:
    """Return the 64-bit FNV-1a hash of ``data`` as an integer."""
    h = _OFFSET
    prime = _PRIME
    mask = _MASK
    for b in data:
        h = ((h ^ b) * prime) & mask
    return h


def format_hash(value: int) -> bytes:
    """Render a hash as exactly 16 lowercase hexadecimal digits."""
    return b"%016x" % value


def hash_hex(data: bytes) -> bytes:
    """Return the 16-digit lowercase hex FNV-1a hash of ``data`` (memoised)."""
    global _memo_bytes
    cached = _MEMO.get(data)
    if cached is not None:
        return cached
    result = format_hash(fnv1a64(data))
    if _memo_bytes + len(data) > _MEMO_LIMIT_BYTES:
        _MEMO.clear()
        _memo_bytes = 0
    _MEMO[data] = result
    _memo_bytes += len(data)
    return result
