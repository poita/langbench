"""Command-line interface.

Reads one JSON document (``{"schema": ..., "tests": [...], "remotes": {...}}``)
from standard input and prints ``valid`` or ``invalid`` for each test.
"""

from __future__ import annotations

import sys
import threading
from typing import List, Optional, Sequence

from .jsonparse import JSONParseError, loads
from .validator import check_document

_USAGE = """\
usage: python3 -m jsonschema2020 < input.json

Read {"schema": ..., "tests": [{"data": ...}, ...], "remotes": {...}} on stdin
and print "valid" or "invalid" for each test, one per line.
"""

#: Deeply nested schemas / instances need far more stack than the default.
_STACK_BYTES = 512 * 1024 * 1024
_RECURSION_LIMIT = 1_000_000


def run(text: str) -> str:
    """Process the input text and return the complete output."""
    results = check_document(loads(text))
    return "".join("valid\n" if ok else "invalid\n" for ok in results)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args:
        sys.stderr.write(_USAGE)
        return 0 if args in (["-h"], ["--help"]) else 2
    data = sys.stdin.buffer.read()
    outcome: List[object] = []

    def work() -> None:
        try:
            outcome.append(run(data.decode("utf-8")))
        except BaseException as exc:  # reported on the main thread
            outcome.append(exc)

    sys.setrecursionlimit(_RECURSION_LIMIT)
    try:
        threading.stack_size(_STACK_BYTES)
    except (ValueError, RuntimeError):
        pass
    thread = threading.Thread(target=work)
    thread.start()
    thread.join()
    result = outcome[0] if outcome else RuntimeError("no result")
    if isinstance(result, str):
        sys.stdout.write(result)
        sys.stdout.flush()
        return 0
    if isinstance(result, (JSONParseError, UnicodeDecodeError)):
        sys.stderr.write(f"error: invalid input: {result}\n")
    else:
        sys.stderr.write(f"error: {type(result).__name__}: {result}\n")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
