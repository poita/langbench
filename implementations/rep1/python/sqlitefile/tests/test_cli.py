import subprocess
import sys
from pathlib import Path

from sqlitefile.cli import main, read_queries

ROOT = Path(__file__).resolve().parents[1]


def make_input(tmp_path, db_bytes, queries, trailing_newline=True):
    inp = tmp_path / "in"
    out = tmp_path / "out"
    inp.mkdir()
    out.mkdir()
    (inp / "x.sqlite").write_bytes(db_bytes)
    (inp / "queries.txt").write_text("\n".join(queries) + ("\n" if trailing_newline else ""))
    return inp, out


def test_cli_writes_one_file_per_query(tmp_path, mini_bytes):
    queries = ["COUNT people", "SELECT nope FROM people", "SELECT id FROM people WHERE id > 100", ".tables"]
    inp, out = make_input(tmp_path, mini_bytes, queries, trailing_newline=False)
    assert main([str(inp), str(out)]) == 0
    assert sorted(p.name for p in out.iterdir()) == ["001.txt", "002.txt", "003.txt", "004.txt"]
    assert (out / "001.txt").read_text() == "4\n"
    assert (out / "002.txt").read_text() == "error\n"
    assert (out / "003.txt").read_bytes() == b""
    assert (out / "004.txt").read_text() == "people\n"


def test_cli_unreadable_database_gives_errors(tmp_path):
    inp, out = make_input(tmp_path, b"not a database", ["COUNT t", ".tables"])
    assert main([str(inp), str(out)]) == 0
    assert (out / "001.txt").read_text() == "error\n"
    assert (out / "002.txt").read_text() == "error\n"


def test_read_queries(tmp_path):
    p = tmp_path / "q"
    p.write_bytes("a\nb c\nd".encode())
    assert read_queries(p) == ["a", "b c", "d"]


def test_module_entry_point(tmp_path, mini_bytes):
    inp, out = make_input(tmp_path, mini_bytes, ["COUNT people"])
    env = {"PYTHONPATH": str(ROOT / "src"), "PATH": "/usr/bin:/bin"}
    r = subprocess.run([sys.executable, "-m", "sqlitefile", str(inp), str(out)], env=env)
    assert r.returncode == 0
    assert (out / "001.txt").read_text() == "4\n"


def test_usage_error():
    assert main([]) == 2
