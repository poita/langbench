import os
import subprocess
import sys

from conftest import read_tree

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def run(*args):
    env = dict(os.environ, PYTHONPATH=os.path.join(ROOT, "src"))
    return subprocess.run([sys.executable, "-m", "sitegen", *args], capture_output=True, text=True, env=env)


def test_cli_generates_site(pond, tmp_path):
    out = tmp_path / "out"
    out.mkdir()
    result = run(pond, str(out))
    assert result.returncode == 0, result.stderr
    assert "index.html" in read_tree(str(out))


def test_run_script(pond, tmp_path):
    out = tmp_path / "out"
    out.mkdir()
    result = subprocess.run([os.path.join(ROOT, "run.sh"), pond, str(out)], capture_output=True, text=True, cwd="/")
    assert result.returncode == 0, result.stderr
    assert (out / "feed.xml").is_file()


def test_cli_wrong_arguments():
    result = run("only-one")
    assert result.returncode == 2
    assert "usage" in result.stderr


def test_cli_help():
    result = run("--help")
    assert result.returncode == 0
    assert "usage" in result.stdout


def test_cli_reports_errors_without_traceback(tmp_path):
    (tmp_path / "empty").mkdir()
    result = run(str(tmp_path / "empty"), str(tmp_path / "out"))
    assert result.returncode == 1
    assert "sitegen: error" in result.stderr
    assert "Traceback" not in result.stderr
