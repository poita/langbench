import io
import subprocess
import sys
from pathlib import Path

from inflate.cli import inflate_hex, main

SRC = str(Path(__file__).resolve().parent.parent / "src")


def run_main(text: bytes) -> bytes:
    out = io.BytesIO()
    assert main(io.BytesIO(text), out) == 0
    return out.getvalue()


def test_examples():
    assert run_main(b"4b4c4a862000\n") == b"616263616263616263\n"
    assert run_main(b"0300\n") == b"\n"
    assert run_main(b"\n") == b"error\n"
    assert run_main(b"030200\n") == b"error\n"


def test_inflate_hex_accepts_str_and_whitespace():
    assert inflate_hex("  010100feff41 \n") == "41"


def test_subprocess_entry_point():
    proc = subprocess.run(
        [sys.executable, "-m", "inflate"],
        input=b"010100feff41\n",
        capture_output=True,
        env={"PYTHONPATH": SRC},
        check=True,
    )
    assert proc.stdout == b"41\n"
