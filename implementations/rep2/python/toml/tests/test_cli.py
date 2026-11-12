import os
import subprocess
import sys
from pathlib import Path

import pytest

from tomlcodec import cli

SRC = str(Path(__file__).resolve().parents[1] / "src")


def run_process(data: bytes) -> subprocess.CompletedProcess:
    env = dict(os.environ, PYTHONPATH=SRC)
    return subprocess.run([sys.executable, "-m", "tomlcodec"], input=data, capture_output=True, env=env)


def test_decode_via_run():
    assert cli.run(b'decode\na = 1\n') == b'{"a":{"type":"integer","value":"1"}}\n'


def test_decode_error():
    assert cli.run(b"decode\na = \n") == b"error\n"
    assert cli.run(b"decode\n\xff") == b"error\n"


def test_encode_via_run():
    assert cli.run(b'encode\n{"a":{"type":"integer","value":"1"}}') == b"a = 1\n"


def test_document_is_verbatim_after_first_newline():
    # The first line is the mode; a leading blank line in the document is part of it.
    assert cli.run(b"decode\n\na = 1") == b'{"a":{"type":"integer","value":"1"}}\n'


def test_bad_mode():
    with pytest.raises(ValueError):
        cli.run(b"frobnicate\n{}")
    with pytest.raises(ValueError):
        cli.run(b"decode")


def test_subprocess_roundtrip():
    r = run_process("decode\ns = 'é'\n".encode())
    assert r.returncode == 0
    assert r.stdout == 'é'.join(['{"s":{"type":"string","value":"', '"}}\n']).encode()


def test_subprocess_deep_nesting():
    depth = 800
    r = run_process(b"decode\na = " + b"[" * depth + b"]" * depth)
    assert r.returncode == 0 and r.stdout.startswith(b'{"a":[[[')


def test_subprocess_usage_error():
    env = dict(os.environ, PYTHONPATH=SRC)
    r = subprocess.run([sys.executable, "-m", "tomlcodec", "x"], capture_output=True, env=env)
    assert r.returncode == 2
