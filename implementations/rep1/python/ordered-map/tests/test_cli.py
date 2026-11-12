import os
import subprocess
import sys
from pathlib import Path

from ordered_map.cli import process

ROOT = Path(__file__).resolve().parent.parent


def test_process_example():
    text = "12\nsize\nmin\ninsert 5 five\ninsert 5 FIVE\nget 5\ninsert 2 two\n" \
           "insert 9 nine\nmin\nmax\nrange 2 9\ndelete 5\nrange 3 8"
    assert process(text).split("\n") == [
        "0", "empty", "ok", "updated", "FIVE", "ok", "ok", "2", "9",
        "2 5 9", "ok", "empty", "",
    ]


def test_zero_commands_is_empty_output():
    assert process("0\n") == ""


def test_values_are_opaque():
    out = process('4\ninsert 1 missing\nget 1\ninsert 2 "\\`#\nget 2\n')
    assert out == 'ok\nmissing\nok\n"\\`#\n'


def test_extreme_keys():
    out = process(
        "5\ninsert 9223372036854775807 hi\nsucc 9223372036854775807\n"
        "insert -9223372036854775808 lo\npred -9223372036854775808\n"
        "range -9223372036854775808 9223372036854775807\n"
    )
    assert out.split("\n") == [
        "ok", "missing", "ok", "missing",
        "-9223372036854775808 9223372036854775807", "",
    ]


def test_subprocess_run_sh():
    env = dict(os.environ)
    res = subprocess.run(
        [str(ROOT / "run.sh")], input=b"2\ninsert 1 a\nselect 0\n",
        capture_output=True, env=env, check=True,
    )
    assert res.stdout == b"ok\n1\n"
