import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent


def run_cli(stdin: bytes, *args: str) -> subprocess.CompletedProcess:
    env = dict(os.environ, PYTHONPATH=str(ROOT / "src"))
    return subprocess.run(
        [sys.executable, "-m", "minisql", *args],
        input=stdin, capture_output=True, env=env, timeout=60,
    )


def test_example_script():
    script = b"""
CREATE TABLE emp (id INTEGER, name TEXT, dept TEXT, salary INTEGER);
INSERT INTO emp VALUES (1, 'ann', 'eng', 120), (2, 'bob', 'ops', 90), (3, 'cy', 'eng', NULL), (4, 'dee', NULL, 100);
SELECT name, salary FROM emp WHERE salary >= 100 ORDER BY salary DESC;
SELECT dept, COUNT(*), SUM(salary), AVG(salary) FROM emp GROUP BY dept;
SELECT * FROM nosuch;
UPDATE emp SET salary = salary + 5 WHERE dept = 'eng';
SELECT id, salary FROM emp;
"""
    expected = (
        "ann\t120\ndee\t100\n-- 2 rows\n"
        "NULL\t1\t100\t100.00\neng\t2\t120\t120.00\nops\t1\t90\t90.00\n-- 3 rows\n"
        "error\n"
        "1\t125\n2\t90\n3\tNULL\n4\t100\n-- 4 rows\n"
    )
    proc = run_cli(script)
    assert proc.returncode == 0
    assert proc.stdout.decode() == expected


@pytest.mark.parametrize("script", [b"", b"  \n-- only a comment\n;;"])
def test_no_output_for_empty_input(script):
    proc = run_cli(script)
    assert proc.returncode == 0 and proc.stdout == b""


def test_missing_final_semicolon_still_runs():
    assert run_cli(b"SELECT 1").stdout == b"1\n-- 1 rows\n"


def test_unterminated_string_stops_execution():
    proc = run_cli(b"SELECT 1; SELECT 'oops; SELECT 2;")
    assert proc.stdout == b"1\n-- 1 rows\nerror\n"


def test_utf8_text_round_trips():
    proc = run_cli("SELECT 'héllo ☃';".encode())
    assert proc.stdout.decode() == "héllo ☃\n-- 1 rows\n"


def test_version_flag():
    proc = run_cli(b"", "--version")
    assert proc.returncode == 0 and proc.stdout.startswith(b"minisql ")
