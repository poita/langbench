"""Text-level helpers: parsing hex patterns and evaluating operation lines."""

from __future__ import annotations

from collections.abc import Callable, Iterable, Iterator

from . import ops

#: Binary operations by name.
BINARY_OPS: dict[str, Callable[[int, int], int]] = {
    "add": ops.add,
    "sub": ops.sub,
    "mul": ops.mul,
    "div": ops.div,
}
#: Unary operations by name.
UNARY_OPS: dict[str, Callable[[int], int]] = {"sqrt": ops.sqrt}


def parse_bits(token: str) -> int:
    """Parse an 8-digit hexadecimal token into a bit pattern."""
    if len(token) != 8:
        raise ValueError(f"expected 8 hex digits, got {token!r}")
    return int(token, 16)


def format_bits(bits: int) -> str:
    """Format a bit pattern as 8 lowercase hexadecimal digits."""
    return f"{bits:08x}"


def evaluate_line(line: str) -> str:
    """Evaluate one ``<op> <a> [<b>]`` line and return the 8-digit result.

    Raises :class:`ValueError` for an unknown operation or wrong arity.
    """
    parts = line.split()
    if not parts:
        raise ValueError("empty line")
    op, args = parts[0], parts[1:]
    if op in BINARY_OPS and len(args) == 2:
        return format_bits(BINARY_OPS[op](parse_bits(args[0]), parse_bits(args[1])))
    if op in UNARY_OPS and len(args) == 1:
        return format_bits(UNARY_OPS[op](parse_bits(args[0])))
    raise ValueError(f"invalid operation line: {line!r}")


def evaluate_lines(lines: Iterable[str]) -> Iterator[str]:
    """Evaluate each line lazily, skipping none."""
    for line in lines:
        yield evaluate_line(line)
