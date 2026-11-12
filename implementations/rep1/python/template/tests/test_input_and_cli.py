import io
import subprocess
import sys
from pathlib import Path

import pytest

from jtemplate.cli import main, run
from jtemplate.inputformat import parse_document

ROOT = Path(__file__).resolve().parents[1]


def test_parse_document_bodies():
    doc = parse_document('{"a": 1,\n "b": [2]}\n--\n=== main\nHello {{ a }}!\n=== other\n\nx\n\n=== last\ntail\n')
    assert list(doc.context) == ["a", "b"]
    assert doc.templates == {"main": "Hello {{ a }}!", "other": "\nx\n", "last": "tail"}
    assert doc.main == "main"


def test_parse_document_no_trailing_newline_and_empty_bodies():
    doc = parse_document("{}\n--\n=== a\n=== b")
    assert doc.templates == {"a": "", "b": ""}
    doc = parse_document("{}\n--\n=== a\n\n")
    assert doc.templates == {"a": ""}


def test_context_member_order_is_preserved():
    doc = parse_document('{"z": 1, "a": 2}\n--\n=== m\n{% for k in d %}{% endfor %}')
    assert list(doc.context) == ["z", "a"]
    assert run('{"d": {"z": 1, "a": 2}}\n--\n=== m\n{% for k in d %}{{ k }}{% endfor %}') == "za"


def test_json_numbers():
    out = run('{"i": 1, "f": 1.0, "e": 1e2, "n": null, "t": true}\n--\n=== m\n{{ i }} {{ f }} {{ e }} {{ n }} {{ t }}\n')
    assert out == "1 1.0 100.0 None True"


@pytest.mark.parametrize("bad", ["{}", "[]\n--\n=== m\n", "{}\n--\n"])
def test_parse_document_errors(bad):
    with pytest.raises(ValueError):
        parse_document(bad)


def test_run_reports_error_line():
    assert run("{}\n--\n=== m\n{{ x }}") == "error: undefined"
    assert run("{}\n--\n=== m\n{% if %}") == "error: syntax"


def test_main_streams():
    out = io.BytesIO()
    status = main([], io.BytesIO('{"n": "é"}\n--\n=== m\n{{ n }}\n'.encode()), out)
    assert status == 0 and out.getvalue() == "é\n".encode()


def test_no_partial_output_on_error():
    assert run("{}\n--\n=== m\nhello {{ 1 / 0 }}") == "error: type"


def test_run_script_end_to_end():
    data = b'{"user": {"name": "Ada"}}\n--\n=== main\nHi {{ user.name|upper }}!\n'
    proc = subprocess.run([str(ROOT / "run.sh")], input=data, capture_output=True, check=True)
    assert proc.stdout == b"Hi ADA!\n"


def test_deep_macro_recursion():
    src = (
        '{}\n--\n=== m\n{% macro f(n) %}{% if n > 0 %}{{ f(n - 1) }}{% else %}done{% endif %}{% endmacro %}{{ f(100) }}'
    )
    proc = subprocess.run([str(ROOT / "run.sh")], input=src.encode(), capture_output=True, check=True)
    assert proc.stdout == b"done\n"
