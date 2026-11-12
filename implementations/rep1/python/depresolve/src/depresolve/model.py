"""Data model: requirements and the package registry."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, Iterator

from .ranges import VersionRange
from .version import Version


@dataclass(frozen=True, slots=True)
class Requirement:
    """A dependency on package *name* at any version inside *range*."""

    name: str
    range: VersionRange

    @classmethod
    def parse(cls, text: str) -> Requirement:
        """Parse ``"name range"``, e.g. ``"left-pad ^1.2.0"``."""
        name, _, rng = text.partition(" ")
        return cls(name, VersionRange.parse(rng))


class Registry:
    """All known package versions with their requirements.

    >>> reg = Registry()
    >>> reg.add("a", Version(1, 0, 0), [Requirement.parse("b *")])
    >>> reg.versions("a")
    [Version(major=1, minor=0, patch=0)]
    """

    def __init__(self) -> None:
        self._packages: dict[str, dict[Version, tuple[Requirement, ...]]] = {}

    def add(
        self, name: str, version: Version, requirements: Iterable[Requirement] = ()
    ) -> None:
        """Declare a package version and its ordered requirements."""
        self._packages.setdefault(name, {})[version] = tuple(requirements)

    def names(self) -> Iterator[str]:
        """Iterate over the names of all packages that have versions."""
        return iter(self._packages)

    def versions(self, name: str) -> list[Version]:
        """Versions of *name*, newest first (empty for an unknown package)."""
        return sorted(self._packages.get(name, ()), reverse=True)

    def requirements(self, name: str, version: Version) -> tuple[Requirement, ...]:
        """The ordered requirements of a registered package version."""
        return self._packages[name][version]

    def __contains__(self, name: object) -> bool:
        return name in self._packages

    def __len__(self) -> int:
        return len(self._packages)
