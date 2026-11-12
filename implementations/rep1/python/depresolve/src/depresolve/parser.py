"""Parser for the registry-plus-root input format."""

from __future__ import annotations

from .model import Registry, Requirement
from .ranges import VersionRange
from .version import Version


def parse_requirements(text: str) -> list[Requirement]:
    """Parse a requirement list: ``""`` or ``" a *, b ^1.0.0"``."""
    text = text.strip()
    if not text:
        return []
    return [Requirement.parse(part) for part in text.split(", ")]


def parse_problem(text: str) -> tuple[Registry, list[Requirement]]:
    """Parse registry lines followed by the final ``root:`` line.

    Returns the registry and the ordered root requirements. The input is
    assumed well formed; malformed lines raise :class:`ValueError`.
    """
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if not lines or not lines[-1].startswith("root:"):
        raise ValueError("input must end with a 'root:' line")
    registry = Registry()
    for line in lines[:-1]:
        head, sep, reqs = line.partition(":")
        if not sep:
            raise ValueError(f"missing ':' in line {line!r}")
        name, _, version = head.partition(" ")
        registry.add(name, Version.parse(version), parse_requirements(reqs))
    return registry, parse_requirements(lines[-1][len("root:"):])
