import subprocess
import sys
from pathlib import Path

import pytest

from protowire import decode, encode, parse_schema
from protowire.requests import process_to_text, split_input

SRC = str(Path(__file__).resolve().parent.parent / "src")


def test_roundtrip_all_kinds(schema):
    text = (
        '{i32: -5, i64: -6, u32: 7, u64: 8, s32: -9, s64: -10, b: true, f32: 11, sf32: -12, '
        'f64: 13, sf64: -14, s: "h\\ni", y: x"00ff", rs: [-1, 0, 1], rf: [1, 2], rb: [false, true], '
        'rstr: ["", "a"], rin: [{}, {v: -1}]}'
    )
    assert decode(schema, "Kinds", encode(schema, "Kinds", text)) == text


def test_depth_64_nesting_roundtrip(schema):
    text = "{r: [1]}"
    for _ in range(63):
        text = "{next: " + text + "}"
    data = encode(schema, "Node", text)
    assert decode(schema, "Node", data) == text


def test_deep_encode_is_linear():
    # a 64-deep chain of messages is written without per-level re-encoding
    schema = parse_schema("message N { N n = 1; bytes b = 2; }")
    text = '{b: x"' + "ab" * 1000 + '"}'
    for _ in range(63):
        text = "{n: " + text + "}"
    assert decode(schema, "N", encode(schema, "N", text)) == text


def test_split_input_variants():
    assert split_input("message A{}\n--\nx\ny") == ("message A{}", ["x", "y"])
    assert split_input("s\n--\nx\n") == ("s", ["x"])
    assert split_input("s\n--\n") == ("s", [])


def test_process_spec_examples():
    inp = (
        "message Inner { sint32 v = 1; }\n"
        "message Outer { int32 a = 1; string b = 2; repeated int32 c = 3; Inner d = 4; }\n--\n"
        "encode Outer {a: 1, b: \"x\", c: [1, 2], d: {v: -5}}\n"
        "decode Outer 08011201781a02010222020809\n"
        "encode Outer {d: {}, c: [], a: 0}\n"
        "decode Outer 3800\n"
        "decode Outer 08ff\n"
        "decode Outer\n"
        "decode Outer \n"
        "decode Outer 0\n"
        "decode Outer 08AA\n"
        "decode Outer 0801 \n"
        "encode Outer\n"
        "encode Outer \n"
        "bogus Outer\n"
    )
    assert process_to_text(inp).split("\n") == [
        "08011201781a02010222020809",
        '{a: 1, b: "x", c: [1, 2], d: {v: -5}}',
        "2200",
        "{}",
        "error",
        "{}",
        "error", "error", "error", "error", "error", "error", "error",
        "",
    ]


def test_empty_encoding_is_empty_line():
    assert process_to_text("message M { int32 a = 1; }\n--\nencode M {}\nencode M {a: 0}") == "\n\n"


def test_cli_end_to_end():
    inp = "message M { int32 a = 1; }\n--\nencode M {a: 300}\ndecode M 08ac02"
    r = subprocess.run(
        [sys.executable, "-m", "protowire"], input=inp.encode(), capture_output=True,
        env={"PYTHONPATH": SRC, "PATH": ""},
    )
    assert r.returncode == 0
    assert r.stdout == b"08ac02\n{a: 300}\n"
