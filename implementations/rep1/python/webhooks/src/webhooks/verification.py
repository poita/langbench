"""Standard Webhooks signature verification."""

from __future__ import annotations

import enum
from collections.abc import Sequence
from dataclasses import dataclass

from .b64 import Base64Error, b64decode
from .signing import compute_mac, signed_content
from .timestamp import parse_canonical_int

__all__ = ["TOLERANCE", "Failure", "VerifyResult", "verify"]

TOLERANCE = 300


class Failure(str, enum.Enum):
    """Why verification failed."""

    MISSING_SIGNATURE = "missing-signature"
    INVALID_TIMESTAMP = "invalid-timestamp"
    TIMESTAMP_TOO_OLD = "timestamp-too-old"
    TIMESTAMP_TOO_NEW = "timestamp-too-new"
    NO_MATCH = "no-match"


@dataclass(frozen=True)
class VerifyResult:
    """Outcome of :func:`verify`.

    On success ``ok`` is true and ``secret_index`` / ``token_index`` locate the
    first matching secret and header token.  On failure ``reason`` is set.
    """

    ok: bool
    secret_index: int | None = None
    token_index: int | None = None
    reason: Failure | None = None

    def __str__(self) -> str:
        if self.ok:
            return f"ok {self.secret_index} {self.token_index}"
        assert self.reason is not None
        return f"fail {self.reason.value}"


def _fail(reason: Failure) -> VerifyResult:
    return VerifyResult(False, reason=reason)


def _candidate_tokens(tokens: list[bytes]) -> list[tuple[int, bytes]]:
    """Tokens of the form ``v1,<valid base64>`` with their decoded MACs."""
    out = []
    for j, token in enumerate(tokens):
        version, comma, value = token.partition(b",")
        if not comma or version != b"v1":
            continue
        try:
            out.append((j, b64decode(value)))
        except Base64Error:
            continue
    return out


def verify(
    keys: Sequence[bytes],
    msg_id: str | bytes,
    timestamp: str | bytes,
    header: str | bytes,
    body: bytes,
    now: int,
) -> VerifyResult:
    """Verify a received webhook.

    *keys* are the active raw keys in order; *msg_id*, *timestamp* and
    *header* are the received ``webhook-id``, ``webhook-timestamp`` and
    ``webhook-signature`` values; *now* is the current Unix time in seconds.
    """
    if isinstance(header, str):
        header = header.encode("utf-8")
    if isinstance(timestamp, str):
        timestamp = timestamp.encode("utf-8")

    tokens = header.split(b" ")
    if all(not t for t in tokens):
        return _fail(Failure.MISSING_SIGNATURE)

    ts = parse_canonical_int(timestamp)
    if ts is None:
        return _fail(Failure.INVALID_TIMESTAMP)

    if now - ts > TOLERANCE:
        return _fail(Failure.TIMESTAMP_TOO_OLD)
    if ts - now > TOLERANCE:
        return _fail(Failure.TIMESTAMP_TOO_NEW)

    candidates = _candidate_tokens(tokens)
    if candidates:
        content = signed_content(msg_id, timestamp, body)
        for i, key in enumerate(keys):
            expected = compute_mac(key, content)  # one MAC per secret
            for j, mac in candidates:
                if mac == expected:
                    return VerifyResult(True, secret_index=i, token_index=j)
    return _fail(Failure.NO_MATCH)
