import os
import subprocess
import sys
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "src"


def run_cli(inp: Path, out: Path) -> subprocess.CompletedProcess:
    env = dict(os.environ, PYTHONPATH=str(SRC))
    return subprocess.run(
        [sys.executable, "-m", "kiln", str(inp), str(out)],
        env=env,
        capture_output=True,
        text=True,
    )


def test_cli_writes_log_and_workspace(tmp_path):
    inp, out = tmp_path / "in", tmp_path / "out"
    (inp / "src").mkdir(parents=True)
    out.mkdir()
    (inp / "src" / "a.txt").write_bytes(b"hi\n")
    (inp / "main.kiln").write_text(
        'step {\n out "out/a.txt"\n in "src/a.txt"\n cmd upper()\n}\ndefault "out/a.txt"\n'
    )
    (inp / "session.txt").write_text("build\nbuild\n")
    proc = run_cli(inp, out)
    assert proc.returncode == 0, proc.stderr
    assert (out / "log.txt").read_text() == (
        "step 1: build (default) -j 1\n"
        "  run 0 2 w0 out/a.txt upper()\n"
        "  ok ran=1 hit=0 time=2\n"
        "step 2: build (default) -j 1\n"
        "  hit 0 out/a.txt\n"
        "  ok ran=0 hit=1 time=0\n"
    )
    assert (out / "workspace" / "out" / "a.txt").read_bytes() == b"HI\n"
    assert (out / "workspace" / "src" / "a.txt").read_bytes() == b"hi\n"
    assert (out / "workspace" / ".kiln-state").exists()
    assert not (out / "workspace" / "session.txt").exists()


def test_cli_build_errors_exit_zero(tmp_path):
    inp, out = tmp_path / "in", tmp_path / "out"
    inp.mkdir()
    (inp / "session.txt").write_text("build\n")
    assert run_cli(inp, out).returncode == 0
    assert (out / "log.txt").read_text().endswith("  error E_NO_BUILD_FILE main.kiln\n")


def test_cli_usage_error(tmp_path):
    proc = subprocess.run(
        [sys.executable, "-m", "kiln"],
        env=dict(os.environ, PYTHONPATH=str(SRC)),
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 2
