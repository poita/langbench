"""Command-line driver: run a script of matrix operations.

Usage::

    python -m linalg <input directory> <output directory>

The input directory holds ``commands.txt`` and the Matrix Market files it
names; one result file per operation result is written to the output
directory (see the README for the format).
"""

from __future__ import annotations

import os
import re
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass

from . import arithmetic, eigen, householder, jacobi_svd, llt, lu, mmio, norms
from .errors import LinalgError
from .matrix import Matrix


@dataclass(frozen=True)
class Operation:
    """A scripted operation: argument count, result-file suffixes and the function."""

    arity: int
    suffixes: tuple[str, ...]
    run: Callable[..., Sequence[Matrix]]


def _scalar(fn: Callable[..., float]) -> Callable[..., Sequence[Matrix]]:
    return lambda *args: (Matrix.scalar(fn(*args)),)


def _single(fn: Callable[..., Matrix]) -> Callable[..., Sequence[Matrix]]:
    return lambda *args: (fn(*args),)


def _lu(a: Matrix) -> Sequence[Matrix]:
    f = lu.lu_factor(a)
    return (f.P, f.L, f.U)


def _eig(a: Matrix) -> Sequence[Matrix]:
    w, v = eigen.eigh(a)
    return (Matrix.from_columns([w]), v)


def _svd_op(a: Matrix) -> Sequence[Matrix]:
    u, s, v = jacobi_svd.svd(a)
    return (u, Matrix.from_columns([s]), v)


def _qr_op(a: Matrix) -> Sequence[Matrix]:
    return householder.qr(a)


OPERATIONS: dict[str, Operation] = {
    "add": Operation(2, ("add",), _single(arithmetic.add)),
    "mul": Operation(2, ("mul",), _single(arithmetic.mul)),
    "transpose": Operation(1, ("transpose",), _single(arithmetic.transpose)),
    "lu": Operation(1, ("lu_P", "lu_L", "lu_U"), _lu),
    "det": Operation(1, ("det",), _scalar(lu.det)),
    "inv": Operation(1, ("inv",), _single(lu.inv)),
    "solve": Operation(2, ("solve",), _single(lu.solve)),
    "qr": Operation(1, ("qr_Q", "qr_R"), _qr_op),
    "chol": Operation(1, ("chol_L",), _single(llt.cholesky)),
    "eig": Operation(1, ("eig_w", "eig_V"), _eig),
    "svd": Operation(1, ("svd_U", "svd_S", "svd_V"), _svd_op),
    "lstsq": Operation(2, ("lstsq",), _single(householder.lstsq)),
    "norm1": Operation(1, ("norm1",), _scalar(norms.norm1)),
    "norminf": Operation(1, ("norminf",), _scalar(norms.norminf)),
    "normfro": Operation(1, ("normfro",), _scalar(norms.normfro)),
    "cond": Operation(1, ("cond",), _scalar(jacobi_svd.cond)),
}

_SPLIT = re.compile(r"[ \t]+")


def parse_commands(text: str) -> list[list[str]]:
    """Split a ``commands.txt`` body into token lists.

    Blank lines and ``#`` comments are dropped (and do not count as commands).
    """
    commands = []
    for line in text.split("\n"):
        line = line.strip(" \t\r")
        if not line or line.startswith("#"):
            continue
        commands.append(_SPLIT.split(line))
    return commands


def run(input_dir: str, output_dir: str) -> None:
    """Execute ``input_dir/commands.txt``, writing results into ``output_dir``."""
    with open(os.path.join(input_dir, "commands.txt"), encoding="utf-8") as handle:
        commands = parse_commands(handle.read())

    cache: dict[str, Matrix] = {}

    def load(name: str) -> Matrix:
        if name not in cache:
            cache[name] = mmio.read_matrix(os.path.join(input_dir, name))
        return cache[name]

    for number, tokens in enumerate(commands, start=1):
        prefix = os.path.join(output_dir, f"{number:03d}_")
        op = OPERATIONS.get(tokens[0])
        try:
            if op is None or len(tokens) != op.arity + 1:
                raise ValueError(f"bad command: {' '.join(tokens)}")
            results = op.run(*(load(name) for name in tokens[1:]))
        except LinalgError as exc:
            with open(prefix + "error.txt", "w", encoding="utf-8", newline="\n") as out:
                out.write(exc.code + "\n")
            continue
        except Exception as exc:  # malformed scripts are unspecified: skip the command
            print(f"command {number} ({tokens[0]}): {exc}", file=sys.stderr)
            continue
        for suffix, matrix in zip(op.suffixes, results):
            mmio.write_matrix(matrix, f"{prefix}{suffix}.mtx")


def main(argv: Sequence[str] | None = None) -> int:
    """Entry point; returns the process exit status."""
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 2:
        print("usage: python -m linalg <input directory> <output directory>", file=sys.stderr)
        return 2
    run(args[0], args[1])
    return 0
