import io
import os
import subprocess
import sys
from pathlib import Path

from chess_perft import cli

ROOT = Path(__file__).resolve().parent.parent

SPEC_EXAMPLE_IN = """\
rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 1
rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 3
r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1 0
"""


def test_process_perft_lines():
    assert list(cli.process(SPEC_EXAMPLE_IN.splitlines())) == ["20", "8902", "1"]


def test_process_divide():
    out = list(cli.process(["8/P1k5/K7/8/8/8/8/8 w - - 0 1 divide 1"]))
    assert out == ["a6a5 1", "a6b5 1", "a7a8b 1", "a7a8n 1", "a7a8q 1", "a7a8r 1", "total 6"]


def test_divide_stalemate_prints_only_total():
    assert list(cli.process(["7k/5Q2/6K1/8/8/8/8/8 b - - 0 1 divide 3"])) == ["total 0"]


def test_divide_castling_example():
    out = list(cli.process(["r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1 divide 2"]))
    assert out[0] == "a1a2 25" and "e1c1 23" in out and out[-1] == "total 568"


def test_main_reads_stdin(monkeypatch, capsys):
    monkeypatch.setattr(sys, "stdin", io.StringIO(SPEC_EXAMPLE_IN.rstrip("\n")))
    assert cli.main([]) == 0
    assert capsys.readouterr().out == "20\n8902\n1\n"


def test_main_empty_input(monkeypatch, capsys):
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    assert cli.main([]) == 0
    assert capsys.readouterr().out == ""


def test_main_rejects_malformed(monkeypatch, capsys):
    monkeypatch.setattr(sys, "stdin", io.StringIO("nonsense\n"))
    assert cli.main([]) == 1
    assert "malformed" in capsys.readouterr().err


def test_run_script_end_to_end():
    proc = subprocess.run(
        [str(ROOT / "run.sh")], input=SPEC_EXAMPLE_IN, capture_output=True, text=True,
        cwd="/", env={**os.environ},
    )
    assert proc.returncode == 0
    assert proc.stdout == "20\n8902\n1\n"
