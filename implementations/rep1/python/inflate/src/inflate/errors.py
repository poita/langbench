"""Exception types raised by the decoder."""

from __future__ import annotations


class InflateError(ValueError):
    """The input is not a valid DEFLATE stream."""


class TruncatedStreamError(InflateError):
    """The stream ended before the final block was complete."""


class TrailingDataError(InflateError):
    """Whole bytes remain after the final block."""
