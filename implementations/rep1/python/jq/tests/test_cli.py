import io
import os
import subprocess
import sys

from jqlite.cli import main

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def cli(data: bytes):
    out = io.BytesIO()
    code = main([], io.BytesIO(data), out)
    return code, out.getvalue().decode()


def test_prints_each_result_as_a_line():
    assert cli(b".[]\n[1,\n 2]\n") == (0, "1\n2\n")


def test_error_after_partial_output():
    assert cli(b".[] | if . == 2 then error else . end\n[1,2,3]") == (0, "1\nerror\n")


def test_no_results_prints_nothing():
    assert cli(b"empty\n1") == (0, "")


def test_unicode_roundtrip():
    assert cli('.\n"é😀\\u0001"'.encode()) == (0, '"é😀\\u0001"\n')


def test_bad_input_is_exit_2():
    assert cli(b"1 +\n1")[0] == 2
    assert cli(b".\n[1,")[0] == 2


def test_module_entry_point():
    env = dict(os.environ, PYTHONPATH=os.path.join(ROOT, "src"))
    p = subprocess.run([sys.executable, "-m", "jqlite"], input=b"map(.+1)\n[1,2]",
                       capture_output=True, env=env)
    assert (p.returncode, p.stdout) == (0, b"[2,3]\n")
