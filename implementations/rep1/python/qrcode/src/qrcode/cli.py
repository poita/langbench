"""Command-line interface.

Reads query lines ``<ecl> <mask|auto> <text>`` from standard input and prints
each symbol as::

    version <v> mask <m>
    <size rows of '#' and '.'>
    <empty line>
"""

from __future__ import annotations

import sys
from typing import BinaryIO, Iterable

from .encoder import encode_bytes
from .errors import InvalidQueryError, QrError
from .tables import ErrorCorrection


def parse_query(line: bytes) -> tuple[ErrorCorrection, int | None, bytes]:
    """Parse one query line (without its newline) into ``(ecl, mask, text)``."""
    parts = line.split(b" ", 2)
    if len(parts) != 3 or not parts[2]:
        raise InvalidQueryError("expected '<ecl> <mask> <text>'")
    ecl_s, mask_s, text = parts
    try:
        ecl = ErrorCorrection[ecl_s.decode("ascii")]
    except (KeyError, UnicodeDecodeError):
        raise InvalidQueryError(f"invalid error correction level: {ecl_s!r}") from None
    if mask_s == b"auto":
        mask = None
    elif len(mask_s) == 1 and mask_s in b"01234567":
        mask = int(mask_s)
    else:
        raise InvalidQueryError(f"invalid mask: {mask_s!r}")
    return ecl, mask, text


def split_queries(data: bytes) -> list[bytes]:
    """Split input into query lines; a final newline is optional."""
    lines = data.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()
    return lines


def render(ecl: ErrorCorrection, mask: int | None, text: bytes) -> str:
    """Encode one query and format its output block."""
    qr = encode_bytes(text, ecl, mask)
    return f"version {qr.version} mask {qr.mask}\n{qr.to_text()}\n"


def run(stdin: BinaryIO, stdout: BinaryIO) -> int:
    lines = split_queries(stdin.read())
    chunks: list[str] = []
    for number, line in enumerate(lines, 1):
        try:
            chunks.append(render(*parse_query(line)))
        except QrError as exc:
            stdout.write("".join(chunks).encode("ascii"))
            stdout.flush()
            print(f"qrcode: line {number}: {exc}", file=sys.stderr)
            return 1
    stdout.write("".join(chunks).encode("ascii"))
    stdout.flush()
    return 0


def main(argv: Iterable[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args:
        print("usage: python -m qrcode < queries.txt   (queries: '<ecl> <mask|auto> <text>')",
              file=sys.stderr)
        return 0 if args in (["-h"], ["--help"]) else 2
    return run(sys.stdin.buffer, sys.stdout.buffer)
