"""The sixteen built-in commands.

Each command is a :class:`CommandSpec` giving its argument signature, input
and output shape, default cost and implementation.  An implementation is a
pure function of the argument values and the input contents (``preprocess``
additionally reads the files it ``@need``s through a ``read`` callback) and
returns a :class:`CommandResult`.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Callable, Sequence

from .errors import KilnError
from .hashing import hash_hex
from .paths import is_workspace_path

__all__ = [
    "CommandSpec", "CommandResult", "COMMANDS", "split_lines", "join_lines",
    "render_command", "escape_string",
]


@dataclass(slots=True)
class CommandResult:
    """What a command produced."""

    content: bytes                      # content of the primary declared output
    depfile: bytes | None = None        # content of the depfile, if any
    discovered: tuple[bytes, ...] = ()  # discovered dependency paths, sorted


Reader = Callable[[bytes], "bytes | None"]


@dataclass(frozen=True, slots=True)
class CommandSpec:
    name: bytes
    arg_types: tuple[str, ...]          # "str" / "int" per argument
    min_inputs: int
    max_inputs: int | None              # None: unbounded
    uses_depfile: bool
    default_cost: int
    run: Callable[[Sequence, Sequence[bytes], Sequence[bytes], Reader], CommandResult]

    @property
    def input_range(self) -> bytes:
        hi = b"N" if self.max_inputs is None else b"%d" % self.max_inputs
        return b"%d-%b" % (self.min_inputs, hi)


# ---- line helpers ---------------------------------------------------------------

def split_lines(content: bytes) -> list[bytes]:
    """The lines of ``content`` (no terminators; empty content has none)."""
    lines = content.split(b"\n")
    if lines[-1] == b"":
        lines.pop()
    return lines


def join_lines(lines: Sequence[bytes]) -> bytes:
    """Concatenate ``lines``, each followed by a newline."""
    if not lines:
        return b""
    return b"\n".join(lines) + b"\n"


# ---- canonical rendering ----------------------------------------------------------

_ESC_RE = re.compile(rb'[\\"\x00-\x1f\x7f]')
_ESC_MAP = {0x5C: b"\\\\", 0x22: b'\\"', 0x0A: b"\\n", 0x09: b"\\t", 0x0D: b"\\r"}


def escape_string(s: bytes) -> bytes:
    """Escape ``s`` as in the canonical command string (without quotes)."""
    def repl(m: re.Match) -> bytes:
        b = m.group()[0]
        return _ESC_MAP.get(b) or b"\\x%02x" % b
    return _ESC_RE.sub(repl, s)


def render_command(name: bytes, args: Sequence) -> bytes:
    """The canonical command string, e.g. ``write("hi\\n")``."""
    rendered = [b"%d" % a if type(a) is int else b'"' + escape_string(a) + b'"' for a in args]
    return name + b"(" + b", ".join(rendered) + b")"


# ---- implementations -----------------------------------------------------------------

def _write(args, paths, contents, read):
    return CommandResult(args[0])


def _copy(args, paths, contents, read):
    return CommandResult(contents[0])


def _concat(args, paths, contents, read):
    return CommandResult(b"".join(contents))


def _upper(args, paths, contents, read):
    return CommandResult(contents[0].upper())


def _lower(args, paths, contents, read):
    return CommandResult(contents[0].lower())


def _grep(args, paths, contents, read):
    needle = args[0]
    return CommandResult(join_lines([l for l in split_lines(contents[0]) if needle in l]))


def _replace(args, paths, contents, read):
    return CommandResult(contents[0].replace(args[0], args[1]))


def _sort_lines(args, paths, contents, read):
    return CommandResult(join_lines(sorted(split_lines(contents[0]))))


def _reverse_lines(args, paths, contents, read):
    return CommandResult(join_lines(split_lines(contents[0])[::-1]))


def _dedup(args, paths, contents, read):
    seen: set[bytes] = set()
    out = []
    for line in split_lines(contents[0]):
        if line not in seen:
            seen.add(line)
            out.append(line)
    return CommandResult(join_lines(out))


def _number(args, paths, contents, read):
    return CommandResult(join_lines([b"%d: %b" % (i, l) for i, l in enumerate(split_lines(contents[0]), 1)]))


def _indent(args, paths, contents, read):
    pad = b" " * args[0]
    return CommandResult(join_lines([pad + l for l in split_lines(contents[0])]))


def _wrap(args, paths, contents, read):
    return CommandResult(args[0] + contents[0] + args[1])


def _count_lines(args, paths, contents, read):
    out = []
    total = 0
    for p, c in zip(paths, contents):
        n = len(split_lines(c))
        total += n
        out.append(b"%d %b" % (n, p))
    out.append(b"%d total" % total)
    return CommandResult(join_lines(out))


def _hash(args, paths, contents, read):
    return CommandResult(join_lines([b"%b %b" % (hash_hex(c), p) for p, c in zip(paths, contents)]))


_NEED = b"@need "


def _preprocess(args, paths, contents, read):
    primary = paths[0]
    on_stack = {primary}
    discovered: set[bytes] = set()
    out: list[bytes] = []
    # Each frame is [path, lines, next line index]; depth-first, left to right.
    stack = [[primary, split_lines(contents[0]), 0]]
    while stack:
        frame = stack[-1]
        path, lines, i = frame
        if i >= len(lines):
            stack.pop()
            on_stack.discard(path)
            continue
        frame[2] = i + 1
        line = lines[i]
        if line.startswith(_NEED) and len(line) > len(_NEED):
            q = line[len(_NEED):]
            if not is_workspace_path(q):
                raise KilnError("E_NEED_PATH", q)
            data = read(q)
            if data is None:
                raise KilnError("E_NEED_MISSING", b"%b needed by %b" % (q, path))
            if q in on_stack:
                raise KilnError("E_NEED_CYCLE", q)
            discovered.add(q)
            on_stack.add(q)
            stack.append([q, split_lines(data), 0])
        else:
            out.append(line)
    found = tuple(sorted(discovered))
    depfile = b"kiln-deps 1\n" + b"".join(b"need %b\n" % q for q in found)
    return CommandResult(join_lines(out), depfile, found)


def _spec(name, arg_types, lo, hi, depfile, cost, run) -> CommandSpec:
    return CommandSpec(name.encode(), tuple(arg_types), lo, hi, depfile, cost, run)


#: The command table, keyed by command name.
COMMANDS: dict[bytes, CommandSpec] = {
    s.name: s
    for s in [
        _spec("write", ["str"], 0, 0, False, 1, _write),
        _spec("copy", [], 1, 1, False, 1, _copy),
        _spec("concat", [], 1, None, False, 2, _concat),
        _spec("upper", [], 1, 1, False, 2, _upper),
        _spec("lower", [], 1, 1, False, 2, _lower),
        _spec("grep", ["str"], 1, 1, False, 3, _grep),
        _spec("replace", ["str", "str"], 1, 1, False, 3, _replace),
        _spec("sort_lines", [], 1, 1, False, 4, _sort_lines),
        _spec("reverse_lines", [], 1, 1, False, 2, _reverse_lines),
        _spec("dedup", [], 1, 1, False, 3, _dedup),
        _spec("number", [], 1, 1, False, 2, _number),
        _spec("indent", ["int"], 1, 1, False, 2, _indent),
        _spec("wrap", ["str", "str"], 1, 1, False, 1, _wrap),
        _spec("count_lines", [], 1, None, False, 2, _count_lines),
        _spec("hash", [], 1, None, False, 3, _hash),
        _spec("preprocess", [], 1, 1, True, 6, _preprocess),
    ]
}
