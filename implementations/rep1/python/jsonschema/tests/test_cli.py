import os
import subprocess
import sys
from pathlib import Path

from jsonschema2020 import cli

ROOT = Path(__file__).resolve().parent.parent


def run_cli(stdin: str):
    env = dict(os.environ, PYTHONPATH=str(ROOT / "src"))
    return subprocess.run(
        [sys.executable, "-m", "jsonschema2020"],
        input=stdin.encode("utf-8"),
        capture_output=True,
        env=env,
    )


EXAMPLE = """{
  "schema": {"type": "integer", "minimum": 1},
  "tests": [
    {"description": "a positive integer", "data": 3},
    {"description": "zero", "data": 0},
    {"description": "a string", "data": "3"}
  ]
}"""


def test_run_function():
    assert cli.run(EXAMPLE) == "valid\ninvalid\ninvalid\n"


def test_subprocess_contract():
    proc = run_cli(EXAMPLE)
    assert proc.returncode == 0
    assert proc.stdout == b"valid\ninvalid\ninvalid\n"
    assert proc.stderr == b""


def test_remotes_and_extra_members_are_handled():
    doc = (
        '{"schema":{"$ref":"http://localhost:1234/int.json"},'
        '"remotes":{"http://localhost:1234/int.json":{"type":"integer"}},'
        '"extra":[1,2],"tests":[{"description":"d","data":1,"valid":true},{"description":"e","data":"x"}]}'
    )
    assert cli.run(doc) == "valid\ninvalid\n"


def test_unicode_input_and_exact_numbers():
    doc = (
        '{"schema":{"type":"string","maxLength":1},'
        '"tests":[{"description":"é","data":"\U0001F4A9"},{"description":"x","data":"é"}]}'
    )
    proc = run_cli(doc)
    assert proc.stdout == b"valid\nvalid\n"
    proc = run_cli('{"schema":{"multipleOf":0.0001},"tests":[{"description":"","data":0.3}]}')
    assert proc.stdout == b"valid\n"


def test_empty_tests():
    assert run_cli('{"schema":true,"tests":[]}').stdout == b""


def test_malformed_input_fails_with_message():
    proc = run_cli("{")
    assert proc.returncode != 0
    assert proc.stdout == b""
    assert b"error" in proc.stderr


def test_missing_members_fail():
    assert run_cli('{"tests":[]}').returncode != 0


def test_deeply_nested_schema_and_instance():
    depth = 2000
    schema = '{"type":"object"}'
    for _ in range(depth):
        schema = '{"properties":{"a":%s}}' % schema
    good = '{"a":' * depth + "{}" + "}" * depth
    bad = '{"a":' * depth + "1" + "}" * depth
    proc = run_cli('{"schema":%s,"tests":[{"description":"g","data":%s},{"description":"b","data":%s}]}' % (schema, good, bad))
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == b"valid\ninvalid\n"
