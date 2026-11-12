"""Command-line interface.

Reads stdin: the first line is the filter, the rest is one JSON document.
Prints each result as compact JSON on its own line; an uncaught runtime error
prints ``error`` (after the results produced so far) and stops.
"""

from __future__ import annotations

import sys
import threading
from typing import BinaryIO, List, Optional

from .errors import JQError, JQSyntaxError, JSONDecodeError
from .jsonio import dumps, loads
from . import Filter


def process(data: bytes) -> "tuple[List[str], bool]":
    """Run the filter/document in ``data``; returns (output lines, errored)."""
    nl = data.find(b"\n")
    if nl < 0:
        filter_bytes, doc_bytes = data, b""
    else:
        filter_bytes, doc_bytes = data[:nl], data[nl + 1 :]
    flt = Filter(filter_bytes.decode("utf-8"))
    doc = loads(doc_bytes.decode("utf-8"))
    lines: List[str] = []
    try:
        for v in flt.run(doc):
            lines.append(dumps(v))
    except JQError:
        return lines, True
    return lines, False


def _main(stdin: BinaryIO, stdout: BinaryIO, result: list) -> None:
    try:
        lines, errored = process(stdin.read())
    except (JQSyntaxError, JSONDecodeError) as e:
        sys.stderr.write(f"jqlite: {e}\n")
        result.append(2)
        return
    if errored:
        lines.append("error")
    if lines:
        lines.append("")
        stdout.write("\n".join(lines).encode("utf-8"))
    stdout.flush()
    result.append(0)


def main(argv: Optional[List[str]] = None) -> int:
    """Entry point; returns the process exit status."""
    args = sys.argv[1:] if argv is None else argv
    if args:
        sys.stderr.write("usage: jqlite   (filter on the first line of stdin, JSON document after)\n")
        return 2
    # Deeply nested filters recurse deeply: run on a thread with a big stack.
    sys.setrecursionlimit(200000)
    threading.stack_size(512 * 1024 * 1024)
    result: list = []
    t = threading.Thread(target=_main, args=(sys.stdin.buffer, sys.stdout.buffer, result))
    t.start()
    t.join()
    return result[0] if result else 1
