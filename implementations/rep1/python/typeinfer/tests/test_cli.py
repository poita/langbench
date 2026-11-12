import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def run(stdin: str, *args: str):
    env = {"PYTHONPATH": str(ROOT / "src"), "PATH": ""}
    return subprocess.run(
        [sys.executable, "-m", "typeinfer", *args],
        input=stdin.encode(), capture_output=True, env=env, cwd=ROOT,
    )


def test_stdin_to_stdout():
    p = run("let id = fun x -> x;;\nid 1;;\nfun x -> x x;;\n")
    assert p.returncode == 0
    assert p.stdout == b"id : 'a -> 'a\n- : int\nerror: occurs\n"


def test_empty_input():
    p = run("")
    assert p.returncode == 0 and p.stdout == b""


def test_file_argument(tmp_path):
    f = tmp_path / "prog.ml"
    f.write_text("1 + 2;;")
    assert run("", str(f)).stdout == b"- : int\n"


def test_syntax_error_is_reported_on_stderr():
    p = run("1;; let = ;;")
    assert p.stdout == b"- : int\n"
    assert p.returncode == 2 and b"syntax error" in p.stderr


def test_run_script():
    p = subprocess.run([str(ROOT / "run.sh")], input=b"true;;", capture_output=True)
    assert p.stdout == b"- : bool\n"
