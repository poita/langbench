"""Exception types shared by the sitegen library."""

from __future__ import annotations


class SitegenError(Exception):
    """Base class of every error raised on purpose by sitegen."""


class TomlError(SitegenError):
    """The text is not in the supported TOML subset."""


class ContentError(SitegenError):
    """A content file or the site configuration is malformed."""
