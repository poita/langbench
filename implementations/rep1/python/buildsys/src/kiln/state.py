"""The ``.kiln-state`` file: strict reader, canonical writer, freshness test."""

from __future__ import annotations

import re
from dataclasses import dataclass

from .paths import is_workspace_path
from .steps import Step
from .vfs import VirtualFS

HEADER = b"kiln-state 1"
_HASH_RE = re.compile(rb"[0-9a-f]{16}")


@dataclass(frozen=True, slots=True)
class Entry:
    """What was recorded when a step last ran successfully."""

    command: bytes
    ins: tuple[tuple[bytes, bytes], ...]  # (path, hash)
    deps: tuple[tuple[bytes, bytes], ...]
    outs: tuple[tuple[bytes, bytes], ...]


State = dict[bytes, Entry]


def _path_hash(rest: bytes) -> tuple[bytes, bytes] | None:
    fields = rest.split(b" ")
    if len(fields) != 2:
        return None
    path, digest = fields
    if not is_workspace_path(path) or _HASH_RE.fullmatch(digest) is None:
        return None
    return path, digest


def parse_state(content: bytes | None) -> State:
    """Parse a state file; any deviation from the grammar yields an empty state."""
    if not content or not content.endswith(b"\n"):
        return {}
    lines = content[:-1].split(b"\n")
    if lines[0] != HEADER:
        return {}
    state: State = {}
    i = 1
    total = len(lines)
    while i < total:
        line = lines[i]
        if not line.startswith(b"step "):
            return {}
        key = line[5:]
        if not is_workspace_path(key) or key in state:
            return {}
        i += 1
        if i >= total or not lines[i].startswith(b"cmd ") or len(lines[i]) == 4:
            return {}
        command = lines[i][4:]
        i += 1
        sections: dict[bytes, list[tuple[bytes, bytes]]] = {b"in": [], b"dep": [], b"out": []}
        stage = 0  # 0: in, 1: dep, 2: out
        order = {b"in": 0, b"dep": 1, b"out": 2}
        while True:
            if i >= total:
                return {}
            line = lines[i]
            i += 1
            if line == b"end":
                break
            word, sep, rest = line.partition(b" ")
            if not sep or word not in order or order[word] < stage:
                return {}
            stage = order[word]
            pair = _path_hash(rest)
            if pair is None:
                return {}
            sections[word].append(pair)
        outs = sections[b"out"]
        if not outs or outs[0][0] != key:
            return {}
        state[key] = Entry(command, tuple(sections[b"in"]), tuple(sections[b"dep"]), tuple(outs))
    return state


def render_state(state: State) -> bytes:
    """Serialise *state* canonically: entries sorted by primary output."""
    out = [HEADER + b"\n"]
    for key in sorted(state):
        e = state[key]
        out.append(b"step " + key + b"\ncmd " + e.command + b"\n")
        for word, pairs in ((b"in ", e.ins), (b"dep ", e.deps), (b"out ", e.outs)):
            for path, digest in pairs:
                out.append(word + path + b" " + digest + b"\n")
        out.append(b"end\n")
    return b"".join(out)


def is_fresh(step: Step, entry: Entry | None, vfs: VirtualFS) -> bool:
    """Change detection: True when *step* may be skipped."""
    if entry is None or entry.command != step.command:
        return False
    outs = entry.outs
    if len(outs) != len(step.full_outputs) or any(
        o[0] != p for o, p in zip(outs, step.full_outputs)
    ):
        return False
    ins = entry.ins
    if len(ins) != len(step.file_inputs) or any(
        i[0] != p for i, p in zip(ins, step.file_inputs)
    ):
        return False
    for group in (ins, entry.deps, outs):
        for path, digest in group:
            if vfs.hash_of(path) != digest:
                return False
    return True


def make_entry(step: Step, input_hashes: list[bytes], dep_hashes: list[tuple[bytes, bytes]],
               out_hashes: list[bytes]) -> Entry:
    """The state entry recorded after *step* ran successfully."""
    return Entry(
        step.command,
        tuple(zip(step.file_inputs, input_hashes)),
        tuple(dep_hashes),
        tuple(zip(step.full_outputs, out_hashes)),
    )
