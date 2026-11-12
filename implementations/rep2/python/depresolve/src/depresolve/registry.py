"""The package registry, requirements, and the text input format."""

from __future__ import annotations

from dataclasses import dataclass, field

from .ranges import Range, parse_range
from .version import Version


@dataclass(frozen=True, slots=True)
class Requirement:
    """A dependency: package ``name`` at a version inside ``range``."""

    name: str
    range: Range


@dataclass(slots=True)
class Registry:
    """All known versions of all packages and their requirements."""

    packages: dict[str, dict[Version, tuple[Requirement, ...]]] = field(
        default_factory=dict
    )

    def add(
        self, name: str, version: Version, requirements: tuple[Requirement, ...] = ()
    ) -> None:
        """Declare a package version and its requirements (in order)."""
        self.packages.setdefault(name, {})[version] = tuple(requirements)

    def versions(self, name: str) -> list[Version]:
        """Versions of ``name``, newest first (empty if unknown)."""
        return sorted(self.packages.get(name, ()), reverse=True)

    def requirements(self, name: str, version: Version) -> tuple[Requirement, ...]:
        """Requirements of one package version, in declared order."""
        return self.packages[name][version]


def parse_requirements(text: str, cache: dict[str, Range] | None = None) -> tuple[Requirement, ...]:
    """Parse ``"a ^1.0.0, b *"`` (the part after the colon, without its
    leading space) into requirements.  ``cache`` memoises range parsing."""
    if not text:
        return ()
    if cache is None:
        cache = {}
    out = []
    for item in text.split(", "):
        name, _, rng = item.partition(" ")
        parsed = cache.get(rng)
        if parsed is None:
            parsed = cache[rng] = parse_range(rng)
        out.append(Requirement(name, parsed))
    return tuple(out)


def parse_input(text: str) -> tuple[Registry, tuple[Requirement, ...]]:
    """Parse registry lines followed by the final ``root:`` line.

    Returns the registry and the root requirements.
    """
    registry = Registry()
    root: tuple[Requirement, ...] = ()
    cache: dict[str, Range] = {}
    for line in text.splitlines():
        if not line:
            continue
        head, _, reqs = line.partition(":")
        reqs = reqs[1:] if reqs else reqs
        if head == "root":
            root = parse_requirements(reqs, cache)
        else:
            name, _, version = head.partition(" ")
            registry.add(name, Version.parse(version), parse_requirements(reqs, cache))
    return registry, root
