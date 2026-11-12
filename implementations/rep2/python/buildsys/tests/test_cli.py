"""The command-line contract."""

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def kiln(*args):
    env = dict(os.environ, PYTHONPATH=str(ROOT / "src"))
    return subprocess.run([sys.executable, "-m", "kiln", *map(str, args)], capture_output=True, env=env)


def test_session_directory_to_output_tree(tmp_path):
    inp, out = tmp_path / "in", tmp_path / "out"
    (inp / "src").mkdir(parents=True)
    (inp / "main.kiln").write_text(
        'step {\n out "out/a.txt"\n in "src/a.txt"\n cmd upper()\n}\ndefault "out/a.txt"\n'
    )
    (inp / "src" / "a.txt").write_text("abc\n")
    (inp / "session.txt").write_text("build\nbuild\n")
    out.mkdir()
    proc = kiln(inp, out)
    assert proc.returncode == 0, proc.stderr
    assert (out / "log.txt").read_text() == (
        "step 1: build (default) -j 1\n  run 0 2 w0 out/a.txt upper()\n  ok ran=1 hit=0 time=2\n"
        "step 2: build (default) -j 1\n  hit 0 out/a.txt\n  ok ran=0 hit=1 time=0\n"
    )
    assert (out / "workspace" / "out" / "a.txt").read_text() == "ABC\n"
    assert (out / "workspace" / "src" / "a.txt").read_text() == "abc\n"
    assert (out / "workspace" / ".kiln-state").exists()
    assert not (out / "workspace" / "session.txt").exists()


def test_build_errors_still_exit_zero(tmp_path):
    inp, out = tmp_path / "in", tmp_path / "out"
    inp.mkdir()
    (inp / "main.kiln").write_text("let = 1\n")
    (inp / "session.txt").write_text("build\n")
    assert kiln(inp, out).returncode == 0
    assert (out / "log.txt").read_text() == "step 1: build (default) -j 1\n  error E_PARSE main.kiln:1\n"


def test_empty_session_gives_empty_log(tmp_path):
    inp, out = tmp_path / "in", tmp_path / "out"
    inp.mkdir()
    (inp / "session.txt").write_text("# nothing\n\n")
    assert kiln(inp, out).returncode == 0
    assert (out / "log.txt").read_bytes() == b""


def test_usage_error():
    assert kiln().returncode == 2
