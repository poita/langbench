import os
import subprocess
import sys
from pathlib import Path

import pytest

from linalg.cli import parse_commands, run

SRC = Path(__file__).resolve().parent.parent / "src"


def write(dirpath, name, text):
    (dirpath / name).write_text(text)


def setup_example(tmp_path):
    inp, out = tmp_path / "in", tmp_path / "out"
    inp.mkdir()
    out.mkdir()
    write(inp, "commands.txt", "# two by two\nadd a.mtx b.mtx\n\ndet a.mtx\nchol s.mtx\n")
    write(inp, "a.mtx", "%%MatrixMarket matrix array real general\n2 2\n1.0\n3.0\n2.0\n4.0\n")
    write(inp, "b.mtx", "%%MatrixMarket matrix coordinate real general\n2 2 2\n1 1 0.5\n2 2 -1.5\n")
    write(inp, "s.mtx", "%%MatrixMarket matrix array real symmetric\n2 2\n4.0\n2.0\n5.0\n")
    return inp, out


def test_parse_commands_skips_blank_and_comments():
    text = "  \n# c\n\t add\ta.mtx   b.mtx \n   # more\ndet a.mtx\n"
    assert parse_commands(text) == [["add", "a.mtx", "b.mtx"], ["det", "a.mtx"]]


def test_spec_worked_example(tmp_path):
    inp, out = setup_example(tmp_path)
    run(str(inp), str(out))
    assert sorted(p.name for p in out.iterdir()) == ["001_add.mtx", "002_det.mtx", "003_chol_L.mtx"]
    assert (out / "001_add.mtx").read_text() == (
        "%%MatrixMarket matrix array real general\n2 2\n"
        "1.5000000000e+00\n3.0000000000e+00\n2.0000000000e+00\n2.5000000000e+00\n"
    )
    assert (out / "002_det.mtx").read_text() == (
        "%%MatrixMarket matrix array real general\n1 1\n-2.0000000000e+00\n"
    )
    assert (out / "003_chol_L.mtx").read_text().split()[7:] == [
        "2.0000000000e+00", "1.0000000000e+00", "0.0000000000e+00", "2.0000000000e+00"
    ]


def test_errors_write_only_error_file_and_script_continues(tmp_path):
    inp, out = tmp_path / "in", tmp_path / "out"
    inp.mkdir()
    out.mkdir()
    write(inp, "commands.txt", "chol r.mtx\nsolve r.mtx c.mtx\nnorm1 r.mtx\n")
    write(inp, "r.mtx", "%%MatrixMarket matrix array real general\n2 3\n1\n2\n3\n4\n5\n6\n")
    write(inp, "c.mtx", "%%MatrixMarket matrix array real general\n3 1\n1\n2\n3\n")
    run(str(inp), str(out))
    assert sorted(p.name for p in out.iterdir()) == ["001_error.txt", "002_error.txt", "003_norm1.mtx"]
    assert (out / "001_error.txt").read_text() == "not_square\n"
    assert (out / "002_error.txt").read_text() == "not_square\n"


def test_multi_file_results_and_numbering(tmp_path):
    inp, out = tmp_path / "in", tmp_path / "out"
    inp.mkdir()
    out.mkdir()
    write(inp, "commands.txt", "lu a.mtx\neig s.mtx\nsvd a.mtx\nqr a.mtx\n")
    write(inp, "a.mtx", "%%MatrixMarket matrix array real general\n2 2\n1\n3\n2\n4\n")
    write(inp, "s.mtx", "%%MatrixMarket matrix array real symmetric\n2 2\n2\n1\n3\n")
    run(str(inp), str(out))
    assert sorted(p.name for p in out.iterdir()) == [
        "001_lu_L.mtx", "001_lu_P.mtx", "001_lu_U.mtx", "002_eig_V.mtx", "002_eig_w.mtx",
        "003_svd_S.mtx", "003_svd_U.mtx", "003_svd_V.mtx", "004_qr_Q.mtx", "004_qr_R.mtx",
    ]


def test_module_entry_point(tmp_path):
    inp, out = setup_example(tmp_path)
    env = dict(os.environ, PYTHONPATH=str(SRC))
    proc = subprocess.run([sys.executable, "-m", "linalg", str(inp), str(out)],
                          env=env, capture_output=True, text=True)
    assert proc.returncode == 0 and proc.stdout == ""
    assert len(list(out.iterdir())) == 3
