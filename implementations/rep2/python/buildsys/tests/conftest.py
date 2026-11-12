"""Shared helpers for the Kiln test-suite."""

from __future__ import annotations

import textwrap

import pytest

from kiln import KilnError, VirtualFS, run_session
from kiln.evaluator import Interpreter, Scope


def dedent(text: str) -> str:
    return textwrap.dedent(text).lstrip("\n")


class Result:
    """The outcome of running a session in memory."""

    def __init__(self, log: bytes, fs: VirtualFS) -> None:
        self.log = log.decode()
        self.fs = fs

    def file(self, path: str) -> str | None:
        data = self.fs.read(path.encode())
        return None if data is None else data.decode()

    def lines(self) -> list[str]:
        return self.log.splitlines()


@pytest.fixture
def session():
    """``session(files, script)`` runs a session and returns a :class:`Result`."""

    def run(files: dict[str, str], script: str) -> Result:
        fs = VirtualFS({k.encode(): v.encode() for k, v in files.items()})
        log = run_session(fs, dedent(script).encode())
        return Result(log, fs)

    return run


@pytest.fixture
def build_error(session):
    """``build_error(main_kiln, files=None)`` -> the ``error`` log line text."""

    def run(main: str, files: dict[str, str] | None = None, script: str = "build") -> str:
        res = session({"main.kiln": dedent(main), **(files or {})}, script)
        errors = [l for l in res.lines() if l.startswith("  error ")]
        assert len(errors) == 1, res.log
        return errors[0][len("  error "):]

    return run


@pytest.fixture
def kbl():
    """``kbl(expr)`` evaluates a KBL expression and returns the Python value."""

    def run(expr: str, files: dict[str, str] | None = None):
        fs = VirtualFS({k.encode(): v.encode() for k, v in (files or {}).items()})
        fs.write(b"main.kiln", b"let result = " + expr.encode())
        scope = Scope()
        Interpreter(fs).run_file(b"main.kiln", scope)
        return scope.vars[b"result"]

    return run


@pytest.fixture
def kbl_error(kbl):
    """``kbl_error(expr)`` -> rendered text of the error evaluating ``expr`` raises."""

    def run(expr: str) -> str:
        with pytest.raises(KilnError) as info:
            kbl(expr)
        return str(info.value)

    return run
