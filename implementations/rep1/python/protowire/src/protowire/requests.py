"""Request-stream processing: the ``schema -- requests`` input format."""

from __future__ import annotations

import re
from collections.abc import Iterable, Iterator

from .decoder import decode_message
from .encoder import encode_message
from .errors import ProtowireError
from .schema import Schema, parse_schema
from .textfmt import format_message
from .textparse import parse_text

ERROR = "error"
_HEX = re.compile(r"[0-9a-f]+")


def split_input(text: str) -> tuple[str, list[str]]:
    """Split program input into ``(schema_text, request_lines)``.

    The schema ends at the first line that is exactly ``--``. Only LF ends a
    line; a final newline does not produce an extra empty request.
    """
    lines = text.split("\n")
    try:
        sep = lines.index("--")
    except ValueError:
        return text, []
    requests = lines[sep + 1 :]
    if requests and requests[-1] == "":
        requests.pop()
    return "\n".join(lines[:sep]), requests


def run_request(schema: Schema, line: str) -> str:
    """Execute one request line and return its output line (``error`` on failure)."""
    try:
        return _run_request(schema, line)
    except ProtowireError:
        return ERROR


def _run_request(schema: Schema, line: str) -> str:
    parts = line.split(" ", 2)
    command = parts[0]
    if command not in ("decode", "encode") or len(parts) < 2:
        raise ProtowireError("bad request")
    desc = schema.get(parts[1])
    if desc is None:
        raise ProtowireError("unknown message")
    rest = parts[2] if len(parts) == 3 else None
    if command == "decode":
        if rest is None:
            data = b""
        elif len(rest) % 2 or _HEX.fullmatch(rest) is None:
            raise ProtowireError("bad hex")
        else:
            data = bytes.fromhex(rest)
        return format_message(decode_message(desc, data))
    if rest is None:
        raise ProtowireError("missing text")
    return encode_message(parse_text(desc, rest)).hex()


def process(text: str) -> Iterator[str]:
    """Run a whole program input, yielding one output line per request."""
    schema_text, requests = split_input(text)
    schema = parse_schema(schema_text)
    for line in requests:
        yield run_request(schema, line)


def process_to_text(text: str) -> str:
    """Like :func:`process`, but return all output lines joined with LF."""
    out = list(process(text))
    return "\n".join(out) + "\n" if out else ""
