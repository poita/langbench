"""The ``.kiln-state`` file: strict reader, canonical writer, freshness.

State is held as a ``dict`` mapping a step's primary output path to a
:class:`StateEntry`.  :func:`parse_state` returns an *empty* dict for any
deviation from the format, as the specification requires.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from .paths import is_workspace_path
from .steps import Step
from .vfs import VirtualFS

__all__ = ["StateEntry", "parse_state", "render_state", "is_fresh", "HEADER"]

HEADER = b"kiln-state 1"
_HASH_RE = re.compile(rb"[0-9a-f]{16}")


@dataclass(slots=True)
class StateEntry:
    """What was recorded for one executed step."""

    key: bytes                              # primary output path
    cmd: bytes                              # canonical command string
    ins: list[tuple[bytes, bytes]]          # (path, hash) of file inputs
    deps: list[tuple[bytes, bytes]]         # discovered dependencies
    outs: list[tuple[bytes, bytes]]         # full output list


def _path_hash(rest: bytes) -> tuple[bytes, bytes] | None:
    fields = rest.split(b" ")
    if len(fields) != 2:
        return None
    path, h = fields
    if not is_workspace_path(path) or _HASH_RE.fullmatch(h) is None:
        return None
    return path, h


def parse_state(data: bytes | None) -> dict[bytes, StateEntry]:
    """Parse a state file; any malformation yields an empty state."""
    if not data or not data.endswith(b"\n"):
        return {}
    lines = data.split(b"\n")
    lines.pop()  # the final newline does not start a further line
    if lines[0] != HEADER:
        return {}
    entries: dict[bytes, StateEntry] = {}
    entry: StateEntry | None = None
    stage = 0           # 0 expect cmd, 1 in*, 2 dep*, 3 out+
    for line in lines[1:]:
        if line == b"end":
            if entry is None or stage != 3 or not entry.outs:
                return {}
            if entry.key != entry.outs[0][0] or entry.key in entries:
                return {}
            entries[entry.key] = entry
            entry = None
            continue
        key, sep, rest = line.partition(b" ")
        if not sep:
            return {}
        if key == b"step":
            if entry is not None or not is_workspace_path(rest):
                return {}
            entry = StateEntry(rest, b"", [], [], [])
            stage = 0
            continue
        if entry is None:
            return {}
        if key == b"cmd":
            if stage != 0 or not rest:
                return {}
            entry.cmd = rest
            stage = 1
            continue
        if stage == 0 or key not in (b"in", b"dep", b"out"):
            return {}
        pair = _path_hash(rest)
        if pair is None:
            return {}
        if key == b"in":
            if stage != 1:
                return {}
            entry.ins.append(pair)
        elif key == b"dep":
            if stage > 2:
                return {}
            stage = 2
            entry.deps.append(pair)
        else:
            stage = 3
            entry.outs.append(pair)
    if entry is not None:
        return {}
    return entries


def render_state(entries: dict[bytes, StateEntry]) -> bytes:
    """The canonical text of ``entries`` (sorted by primary output path)."""
    out: list[bytes] = [HEADER]
    for key in sorted(entries):
        e = entries[key]
        out.append(b"step " + key)
        out.append(b"cmd " + e.cmd)
        for tag, pairs in ((b"in ", e.ins), (b"dep ", e.deps), (b"out ", e.outs)):
            for path, h in pairs:
                out.append(tag + path + b" " + h)
        out.append(b"end")
    return b"\n".join(out) + b"\n"


def is_fresh(entry: StateEntry | None, step: Step, fs: VirtualFS) -> bool:
    """Decide whether ``step`` is a cache hit given its state ``entry``."""
    if entry is None or entry.cmd != step.command:
        return False
    if len(entry.outs) != len(step.outputs) or len(entry.ins) != len(step.file_inputs):
        return False
    if any(p != q for (p, _), q in zip(entry.outs, step.outputs)):
        return False
    if any(p != q for (p, _), q in zip(entry.ins, step.file_inputs)):
        return False
    for pairs in (entry.ins, entry.deps, entry.outs):
        for path, h in pairs:
            if fs.hash(path) != h:
                return False
    return True
