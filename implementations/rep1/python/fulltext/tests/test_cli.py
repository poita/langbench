import subprocess
import sys
from pathlib import Path

from fulltext.cli import main

SRC = str(Path(__file__).resolve().parents[1] / "src")


def make_input(tmp_path):
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs" / "note.txt").write_text(
        "The quick brown fox jumps over the lazy dog.\n", encoding="utf-8"
    )
    (tmp_path / "docs" / "ignored.md").write_text("fox", encoding="utf-8")
    (tmp_path / "queries.txt").write_text("fox\nquick brown\ncat\n\"lazy dog\"", encoding="utf-8")
    return tmp_path


def test_main_writes_both_files(tmp_path):
    inp = tmp_path / "in"
    inp.mkdir()
    make_input(inp)
    out = tmp_path / "out"
    out.mkdir()
    assert main([str(inp), str(out)]) == 0
    assert sorted(p.name for p in out.iterdir()) == ["results.txt", "stats.txt"]
    assert (out / "results.txt").read_text(encoding="utf-8") == (
        "QUERY 1 fox\nHITS 1\n1\tnote\t0.2877\tThe quick brown fox jumps over the lazy dog\n"
        "QUERY 2 quick brown\nHITS 1\n1\tnote\t0.5754\tThe quick brown fox jumps over the lazy dog\n"
        "QUERY 3 cat\nHITS 0\n"
        'QUERY 4 "lazy dog"\nHITS 1\n1\tnote\t0.2877\tThe quick brown fox jumps over the lazy dog\n'
    )
    assert (out / "stats.txt").read_text(encoding="utf-8") == (
        "documents 1\ntokens 9\nterms 8\navgdl 9.0000\n"
    )


def test_missing_docs_directory(tmp_path):
    (tmp_path / "queries.txt").write_text("cat\n", encoding="utf-8")
    out = tmp_path / "out"
    out.mkdir()
    assert main([str(tmp_path), str(out)]) == 0
    assert (out / "results.txt").read_text() == "QUERY 1 cat\nHITS 0\n"
    assert (out / "stats.txt").read_text().startswith("documents 0\n")


def test_python_m_invocation(tmp_path):
    inp = tmp_path / "in"
    inp.mkdir()
    make_input(inp)
    out = tmp_path / "out"
    out.mkdir()
    result = subprocess.run(
        [sys.executable, "-m", "fulltext", str(inp), str(out)],
        env={"PYTHONPATH": SRC},
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert (out / "results.txt").exists()
