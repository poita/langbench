import subprocess
import sys
from pathlib import Path

SRC = str(Path(__file__).resolve().parent.parent / "src")


def run(data: bytes, *args: str) -> subprocess.CompletedProcess:
    import os

    env = dict(os.environ, PYTHONPATH=SRC)
    return subprocess.run([sys.executable, "-m", "cmarkpy", *args], input=data, capture_output=True, env=env)


def test_stdin_to_stdout():
    r = run("# Hi *there* é\n".encode())
    assert r.returncode == 0
    assert r.stdout == "<h1>Hi <em>there</em> é</h1>\n".encode()


def test_empty_input():
    r = run(b"")
    assert r.returncode == 0 and r.stdout == b""


def test_file_argument(tmp_path):
    f = tmp_path / "x.md"
    f.write_text("- a\n- b\n", encoding="utf-8")
    r = run(b"", str(f))
    assert r.stdout == b"<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n"


def test_version():
    r = run(b"", "--version")
    assert r.returncode == 0 and r.stdout.startswith(b"cmarkpy")
