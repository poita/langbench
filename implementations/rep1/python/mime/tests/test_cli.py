import os
import subprocess
import sys
from pathlib import Path

from mimedump.cli import main

SRC = str(Path(__file__).resolve().parent.parent / "src")


def test_cli_dumps_mbox(tmp_path):
    inp = tmp_path / "box"
    inp.write_bytes(
        b"From x\nSubject: hi\nContent-Type: application/x-thing\n"
        b"Content-Transfer-Encoding: base64\n\nAAEC\n\n"
        b"From y\nSubject: two\n\nbody\n"
    )
    out = tmp_path / "out"
    assert main([str(inp), str(out)]) == 0
    assert (out / "summary.txt").read_text() == (
        "messages 2\n"
        '0001 source="mbox:1" bytes=%d parts=1 attachments=1 text=- html=-\n'
        '0002 source="mbox:2" bytes=%d parts=1 attachments=0 text=0 html=-\n'
    ) % (len(b"Subject: hi\nContent-Type: application/x-thing\nContent-Transfer-Encoding: base64\n\nAAEC\n"), 19)
    assert (out / "parts" / "0001" / "000.bin").read_bytes() == b"\x00\x01\x02"
    assert not (out / "parts" / "0002").exists()
    assert (out / "messages" / "0002.txt").exists()


def test_cli_directory_and_missing_output(tmp_path):
    (tmp_path / "in").mkdir()
    (tmp_path / "in" / "a.eml").write_bytes(b"Subject: x\r\n\r\nhi\r\n")
    out = tmp_path / "new" / "out"
    assert main([str(tmp_path / "in"), str(out)]) == 0
    assert 'source="a.eml"' in (out / "summary.txt").read_text()


def test_cli_missing_input_returns_1(tmp_path, capsys):
    assert main([str(tmp_path / "nope"), str(tmp_path / "out")]) == 1
    assert "mimedump:" in capsys.readouterr().err


def test_module_entry_point(tmp_path):
    inp = tmp_path / "a.eml"
    inp.write_bytes(b"Subject: x\n\nbody\n")
    out = tmp_path / "out"
    out.mkdir()
    env = dict(os.environ, PYTHONPATH=SRC)
    done = subprocess.run([sys.executable, "-m", "mimedump", str(inp), str(out)], env=env)
    assert done.returncode == 0
    # A regular file is an mbox without separator lines: no messages.
    assert (out / "summary.txt").read_text() == "messages 0\n"
