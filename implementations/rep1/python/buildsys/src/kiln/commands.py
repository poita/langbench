"""The sixteen built-in commands.

Each command is a :class:`CommandSpec` describing its signature and shape
constraints plus a pure function computing the content to write.  Commands never
touch the file system themselves: they receive the file inputs' contents (read
when the command starts) and a *reader* for files discovered at run time, and
return a :class:`CommandResult`.
"""

from __future__ import annotations

from collections.abc import Callable, Sequence
from dataclasses import dataclass

from .errors import KilnError, arity_error, type_error
from .hashing import hash_hex
from .paths import is_workspace_path
from .values import type_name

Reader = Callable[[bytes], "bytes | None"]


@dataclass(frozen=True, slots=True)
class CommandResult:
    """What a command produced."""

    output: bytes
    #: Depfile content (``preprocess`` only).
    depfile: bytes | None = None
    #: Paths read beyond the declared inputs, sorted.
    discovered: tuple[bytes, ...] = ()


def split_lines(content: bytes) -> list[bytes]:
    """The lines of *content* as defined by the specification."""
    if not content:
        return []
    lines = content.split(b"\n")
    if not lines[-1]:
        lines.pop()
    return lines


def join_lines(lines: Sequence[bytes]) -> bytes:
    """Concatenate *lines*, each followed by a newline."""
    return b"".join([ln + b"\n" for ln in lines])


# -- implementations -----------------------------------------------------------

Inputs = Sequence[tuple[bytes, bytes]]  # (path, content) pairs


def _write(args: tuple, inputs: Inputs, read: Reader) -> CommandResult:
    return CommandResult(args[0])


def _copy(args: tuple, inputs: Inputs, read: Reader) -> CommandResult:
    return CommandResult(inputs[0][1])


def _concat(args: tuple, inputs: Inputs, read: Reader) -> CommandResult:
    return CommandResult(b"".join([c for _p, c in inputs]))


def _upper(args: tuple, inputs: Inputs, read: Reader) -> CommandResult:
    return CommandResult(inputs[0][1].upper())


def _lower(args: tuple, inputs: Inputs, read: Reader) -> CommandResult:
    return CommandResult(inputs[0][1].lower())


def _grep(args: tuple, inputs: Inputs, read: Reader) -> CommandResult:
    needle = args[0]
    return CommandResult(join_lines([ln for ln in split_lines(inputs[0][1]) if needle in ln]))


def _replace(args: tuple, inputs: Inputs, read: Reader) -> CommandResult:
    return CommandResult(inputs[0][1].replace(args[0], args[1]))


def _sort_lines(args: tuple, inputs: Inputs, read: Reader) -> CommandResult:
    return CommandResult(join_lines(sorted(split_lines(inputs[0][1]))))


def _reverse_lines(args: tuple, inputs: Inputs, read: Reader) -> CommandResult:
    return CommandResult(join_lines(split_lines(inputs[0][1])[::-1]))


def _dedup(args: tuple, inputs: Inputs, read: Reader) -> CommandResult:
    seen: set[bytes] = set()
    kept = []
    for ln in split_lines(inputs[0][1]):
        if ln not in seen:
            seen.add(ln)
            kept.append(ln)
    return CommandResult(join_lines(kept))


def _number(args: tuple, inputs: Inputs, read: Reader) -> CommandResult:
    lines = split_lines(inputs[0][1])
    return CommandResult(b"".join([b"%d: %s\n" % (i, ln) for i, ln in enumerate(lines, 1)]))


def _indent(args: tuple, inputs: Inputs, read: Reader) -> CommandResult:
    pad = b" " * args[0]
    return CommandResult(join_lines([pad + ln for ln in split_lines(inputs[0][1])]))


def _wrap(args: tuple, inputs: Inputs, read: Reader) -> CommandResult:
    return CommandResult(args[0] + inputs[0][1] + args[1])


def _count_lines(args: tuple, inputs: Inputs, read: Reader) -> CommandResult:
    out = []
    total = 0
    for path, content in inputs:
        count = len(split_lines(content))
        total += count
        out.append(b"%d %s\n" % (count, path))
    out.append(b"%d total\n" % total)
    return CommandResult(b"".join(out))


def _hash(args: tuple, inputs: Inputs, read: Reader) -> CommandResult:
    return CommandResult(b"".join([hash_hex(c) + b" " + p + b"\n" for p, c in inputs]))


_NEED = b"@need "


def _preprocess(args: tuple, inputs: Inputs, read: Reader) -> CommandResult:
    """Expand ``@need`` directives depth-first, recording the files read."""
    root, content = inputs[0]
    discovered: set[bytes] = set()
    out: list[bytes] = []
    on_stack = {root}
    # Frames: (path, lines, next line index).  Iterative so that deep @need
    # chains cannot exhaust the interpreter stack.
    stack: list[tuple[bytes, list[bytes], int]] = [(root, split_lines(content), 0)]
    while stack:
        path, lines, i = stack.pop()
        descended = False
        while i < len(lines):
            line = lines[i]
            i += 1
            if line.startswith(_NEED) and len(line) > len(_NEED):
                q = line[len(_NEED):]
                if not is_workspace_path(q):
                    raise KilnError("E_NEED_PATH", q)
                data = read(q)
                if data is None:
                    raise KilnError("E_NEED_MISSING", q + b" needed by " + path)
                if q in on_stack:
                    raise KilnError("E_NEED_CYCLE", q)
                discovered.add(q)
                stack.append((path, lines, i))
                on_stack.add(q)
                stack.append((q, split_lines(data), 0))
                descended = True
                break
            out.append(line)
        if not descended:
            on_stack.discard(path)
    found = tuple(sorted(discovered))
    depfile = b"kiln-deps 1\n" + b"".join([b"need " + p + b"\n" for p in found])
    return CommandResult(join_lines(out), depfile, found)


# -- the command table ---------------------------------------------------------


@dataclass(frozen=True, slots=True)
class CommandSpec:
    """Signature, shape constraints and implementation of one command."""

    name: str
    arg_types: tuple[str, ...]
    min_inputs: int
    max_inputs: int | None  # ``None``: any number >= min_inputs
    uses_depfile: bool
    default_cost: int
    run: Callable[[tuple, Inputs, Reader], CommandResult]

    def check_args(self, args: Sequence[object]) -> None:
        """Validate argument count then types (``E_ARITY`` / ``E_TYPE``)."""
        if len(args) != len(self.arg_types):
            raise arity_error("cmd", self.name, str(len(self.arg_types)), len(args))
        for i, (arg, expected) in enumerate(zip(args, self.arg_types), 1):
            actual = type_name(arg)
            if actual != expected:
                raise type_error(f"cmd {self.name} argument {i}", expected, actual)

    def input_range(self) -> str:
        """The ``lo-hi`` text used by ``E_CMD_SHAPE``."""
        hi = "N" if self.max_inputs is None else str(self.max_inputs)
        return f"{self.min_inputs}-{hi}"

    def check_semantics(self, args: Sequence[object]) -> None:
        """Command-specific argument checks (``E_ARG cmd``)."""
        if self.name == "replace" and not args[0]:
            raise KilnError("E_ARG", "cmd replace: empty pattern")
        if self.name == "indent" and args[0] < 0:  # type: ignore[operator]
            raise KilnError("E_ARG", "cmd indent: negative")


def _table() -> dict[bytes, CommandSpec]:
    rows = [
        ("write", ("str",), 0, 0, False, 1, _write),
        ("copy", (), 1, 1, False, 1, _copy),
        ("concat", (), 1, None, False, 2, _concat),
        ("upper", (), 1, 1, False, 2, _upper),
        ("lower", (), 1, 1, False, 2, _lower),
        ("grep", ("str",), 1, 1, False, 3, _grep),
        ("replace", ("str", "str"), 1, 1, False, 3, _replace),
        ("sort_lines", (), 1, 1, False, 4, _sort_lines),
        ("reverse_lines", (), 1, 1, False, 2, _reverse_lines),
        ("dedup", (), 1, 1, False, 3, _dedup),
        ("number", (), 1, 1, False, 2, _number),
        ("indent", ("int",), 1, 1, False, 2, _indent),
        ("wrap", ("str", "str"), 1, 1, False, 1, _wrap),
        ("count_lines", (), 1, None, False, 2, _count_lines),
        ("hash", (), 1, None, False, 3, _hash),
        ("preprocess", (), 1, 1, True, 6, _preprocess),
    ]
    return {r[0].encode(): CommandSpec(*r) for r in rows}


COMMANDS: dict[bytes, CommandSpec] = _table()


def lookup_command(name: bytes) -> CommandSpec:
    """The command called *name*; ``E_UNKNOWN_CMD`` when there is none."""
    spec = COMMANDS.get(name)
    if spec is None:
        raise KilnError("E_UNKNOWN_CMD", name)
    return spec


def _escape(s: bytes) -> bytes:
    out = bytearray()
    for b in s:
        if b == 0x5C:
            out += b"\\\\"
        elif b == 0x22:
            out += b'\\"'
        elif b == 0x0A:
            out += b"\\n"
        elif b == 0x09:
            out += b"\\t"
        elif b == 0x0D:
            out += b"\\r"
        elif b < 0x20 or b == 0x7F:
            out += b"\\x%02x" % b
        else:
            out.append(b)
    return bytes(out)


def render_command(name: bytes, args: Sequence[object]) -> bytes:
    """Canonical command string, e.g. ``write("hi\\n")`` or ``indent(4)``."""
    rendered = []
    for a in args:
        if type(a) is bytes:
            rendered.append(b'"' + _escape(a) + b'"')
        else:
            rendered.append(b"%d" % a)
    return name + b"(" + b", ".join(rendered) + b")"
