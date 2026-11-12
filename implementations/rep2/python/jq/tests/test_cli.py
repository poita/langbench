import os
import subprocess
import sys

from jqlite.cli import process

HERE = os.path.dirname(__file__)
SRC = os.path.join(HERE, "..", "src")


def run_cli(stdin: bytes):
    env = dict(os.environ, PYTHONPATH=SRC)
    p = subprocess.run([sys.executable, "-m", "jqlite"], input=stdin, capture_output=True, env=env)
    return p.returncode, p.stdout.decode()


def test_basic():
    assert run_cli(b".a\n{\"a\": [1, 2]}\n") == (0, "[1,2]\n")


def test_multiple_outputs_and_error():
    assert run_cli(b".[] | 1 / .\n[1,2,0,4]") == (0, "1\n0.5\nerror\n")


def test_no_output():
    assert run_cli(b"empty\n1") == (0, "")


def test_utf8_and_multiline_document():
    assert run_cli('.[]\n[\n "é😀",\n"\\ud83d\\ude00"\n]\n'.encode()) == (0, '"é😀"\n"😀"\n')


def test_process_function():
    assert process(b".\n[1]") == (["[1]"], False)
    assert process(b".[],error\n[1]") == (["1"], True)


def test_bad_filter_exit_status():
    code, out = run_cli(b"(\n1")
    assert code == 2 and out == ""


def test_very_long_pipe_chain_uses_big_stack():
    flt = " | ".join(["."] * 900).encode()
    assert run_cli(flt + b"\n1") == (0, "1\n")
