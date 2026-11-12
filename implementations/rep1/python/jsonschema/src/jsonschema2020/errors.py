"""Exception types raised by the library."""

from __future__ import annotations

__all__ = ["SchemaError", "RefResolutionError"]


class SchemaError(ValueError):
    """A schema is structurally unusable (e.g. a non-schema where a schema is
    required, or an invalid regular expression)."""


class RefResolutionError(LookupError):
    """A ``$ref`` / ``$dynamicRef`` does not resolve to a known schema."""
