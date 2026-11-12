import os
import subprocess
import sys

from tessera.cli import main

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def test_cli_writes_the_three_files(tmp_path):
    src, dst = tmp_path / "in", tmp_path / "out"
    src.mkdir()
    (src / "commands.txt").write_text('put "a" 1\nget "a"')
    assert main([str(src), str(dst)]) == 0
    assert sorted(os.listdir(dst)) == ["main.tdb", "main.twal", "results.txt"]
    assert (dst / "results.txt").read_text() == '[1] ok put created\n[2] ok get value\n  1\n'
    assert len((dst / "main.tdb").read_bytes()) == 1024
    assert len((dst / "main.twal").read_bytes()) == 2152


def test_cli_continues_from_existing_files(tmp_path):
    first, second, third = (tmp_path / n for n in ("one", "two", "three"))
    first.mkdir()
    (first / "commands.txt").write_text('put "a" [1,2]\ncheckpoint\nput "b" 2\n')
    main([str(first), str(second)])
    (second / "commands.txt").write_text('scan\n')
    main([str(second), str(third)])
    assert (third / "results.txt").read_text() == '[1] ok scan 2\n  "a" = [1,2]\n  "b" = 2\n'
    for name in ("main.tdb", "main.twal"):
        assert (third / name).read_bytes() == (second / name).read_bytes()


def test_empty_script_and_fresh_database(tmp_path):
    src = tmp_path / "in"
    src.mkdir()
    (src / "commands.txt").write_bytes(b"")
    main([str(src), str(tmp_path / "out")])
    assert (tmp_path / "out" / "results.txt").read_bytes() == b""
    assert (tmp_path / "out" / "main.tdb").read_bytes()[:12].hex() == "544553534552413100010400"


def test_module_entry_point_and_usage(tmp_path):
    env = dict(os.environ, PYTHONPATH=os.path.join(ROOT, "src"))
    r = subprocess.run([sys.executable, "-m", "tessera"], env=env, capture_output=True)
    assert r.returncode == 2
