"""Semantic versions (``MAJOR.MINOR.PATCH``, no prerelease or build parts)."""

from __future__ import annotations

from typing import NamedTuple


class Version(NamedTuple):
    """A three-component version; compares numerically, major first."""

    major: int
    minor: int
    patch: int

    @classmethod
    def parse(cls, text: str) -> Version:
        """Parse ``"1.10.0"`` into ``Version(1, 10, 0)``."""
        major, minor, patch = text.split(".")
        return cls(int(major), int(minor), int(patch))

    def successor(self) -> Version:
        """The next version after this one (versions are integral)."""
        return Version(self.major, self.minor, self.patch + 1)

    def __str__(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"
