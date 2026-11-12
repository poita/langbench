"""Command-line entry point: schema and requests on stdin, results on stdout."""

from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence

from . import __version__
from .errors import SchemaError
from .requests import process_to_text


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="protowire",
        description=(
            "Read a message schema and decode/encode requests from stdin "
            "(schema, a line '--', then one request per line); print one "
            "result line per request."
        ),
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    parser.parse_args(argv)

    data = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    try:
        output = process_to_text(data)
    except SchemaError as exc:
        print(f"protowire: invalid schema: {exc}", file=sys.stderr)
        return 2
    sys.stdout.buffer.write(output.encode("utf-8"))
    sys.stdout.buffer.flush()
    return 0
