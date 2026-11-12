import os
import subprocess
import sys

from svgraster.batch import parse_render_list
from svgraster.cli import main

SRC = os.path.join(os.path.dirname(__file__), "..", "src")


def test_parse_render_list():
    text = "# c\n\n  \na.svg 4 3\r\n  # x\nb.svg  5\t6\n"
    assert parse_render_list(text) == [("a.svg", 4, 3), ("b.svg", 5, 6)]


def test_main_writes_ppm_files(tmp_path):
    inp, out = tmp_path / "in", tmp_path / "out" / "nested"
    inp.mkdir()
    (inp / "a.svg").write_text('<svg viewBox="0 0 2 2"><rect width="2" height="2" fill="#fff"/></svg>')
    (inp / "render.txt").write_text("a.svg 2 2\n")
    assert main([str(inp), str(out)]) == 0
    assert (out / "a.ppm").read_bytes() == b"P6\n2 2\n255\n" + b"\xff" * 12


def test_main_usage_and_missing_file(tmp_path):
    assert main([]) == 2
    (tmp_path / "render.txt").write_text("nope.svg 1 1\n")
    assert main([str(tmp_path), str(tmp_path / "o")]) == 1


def test_module_entry_point(tmp_path):
    (tmp_path / "render.txt").write_text("")
    env = dict(os.environ, PYTHONPATH=SRC)
    r = subprocess.run([sys.executable, "-m", "svgraster", str(tmp_path), str(tmp_path / "o")],
                       env=env)
    assert r.returncode == 0
