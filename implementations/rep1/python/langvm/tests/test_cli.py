import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def run_cli(stdin: bytes) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "-m", "langvm"],
        input=stdin,
        capture_output=True,
        env={"PYTHONPATH": str(ROOT / "src"), "PATH": ""},
        timeout=60,
    )


def test_successful_program_exit_code_zero():
    r = run_cli(b'@module main\nfn main() { print("h\xc3\xa9llo"); }\n')
    assert r.returncode == 0 and r.stdout == "héllo\n".encode()


def test_compile_error_prints_one_line_and_exits_zero():
    r = run_cli(b"@module main\nfn main() { 1 }\n")
    assert r.returncode == 0 and r.stdout == b"error: type-mismatch at 1:13\n"


def test_panic_exits_zero():
    r = run_cli(b'@module main\nfn main() { emit("a"); panic("boom"); }\n')
    assert r.returncode == 0 and r.stdout == b"apanic: boom\n"


def test_empty_input_is_bad_module():
    assert run_cli(b"").stdout == b"error: bad-module at 1:1\n"


def test_run_script_works_from_any_directory(tmp_path):
    r = subprocess.run(
        [str(ROOT / "run.sh")],
        input=b'@module main\nfn main() { print("ok"); }\n',
        capture_output=True,
        cwd=tmp_path,
        timeout=60,
    )
    assert r.stdout == b"ok\n"
