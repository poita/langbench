import os
import subprocess
import sys
from pathlib import Path

import pytest

SRC = str(Path(__file__).resolve().parent.parent / "src")


def run(payload: bytes) -> subprocess.CompletedProcess:
    env = dict(os.environ, PYTHONPATH=SRC)
    return subprocess.run(
        [sys.executable, "-m", "tomlcodec"], input=payload, capture_output=True, env=env, check=True
    )


def test_decode():
    assert run(b"decode\na = 1\n").stdout == b'{"a":{"type":"integer","value":"1"}}\n'


def test_decode_empty_document():
    assert run(b"decode\n").stdout == b"{}\n"


@pytest.mark.parametrize("doc", [b"a = ", b"\xff", b"a = 1\rb = 2"])
def test_decode_error_exits_zero(doc):
    result = run(b"decode\n" + doc)
    assert result.stdout == b"error\n"
    assert result.returncode == 0


def test_encode():
    out = run(b'encode\n{"a":{"type":"string","value":"x"}}').stdout
    assert out == b'a = "x"\n'


def test_encode_empty():
    assert run(b"encode\n{}").stdout == b"\n"
