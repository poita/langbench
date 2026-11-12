import io
import subprocess
import sys
from pathlib import Path

from rrule.cli import process_line, run

ROOT = Path(__file__).resolve().parent.parent


def test_process_line():
    assert process_line("20240229T120000 FREQ=YEARLY;COUNT=3 10") == "20240229T120000 20280229T120000 20320229T120000"
    assert process_line("20240229T120000 FREQ=YEARLY;COUNT=3 2") == "20240229T120000 20280229T120000"
    assert process_line("20260101T000000 FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30;COUNT=5 10") == ""


def test_run_missing_final_newline_and_empty_result():
    out = io.StringIO()
    run(["20240101T000000 FREQ=DAILY;COUNT=2 5\n", "20260101T000000 FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30 5"], out)
    assert out.getvalue() == "20240101T000000 20240102T000000\n\n"


def test_module_entry_point_end_to_end():
    result = subprocess.run(
        [sys.executable, "-m", "rrule"],
        input="19970902T090000 FREQ=DAILY;COUNT=2 100\n",
        capture_output=True,
        text=True,
        env={"PYTHONPATH": str(ROOT / "src")},
        check=True,
    )
    assert result.stdout == "19970902T090000 19970903T090000\n"
