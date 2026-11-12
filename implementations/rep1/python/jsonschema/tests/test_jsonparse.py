from fractions import Fraction

import pytest

from jsonschema2020 import JSONParseError, loads


def test_scalars():
    assert loads("null") is None
    assert loads(" true ") is True
    assert loads("false") is False
    assert loads('"abc"') == "abc"


@pytest.mark.parametrize("text", ["1", "1.0", "1.00", "1e0", "100e-2", "0.1e1"])
def test_equal_numbers_become_the_same_int(text):
    value = loads(text)
    assert value == 1 and type(value) is int


def test_numbers_are_exact():
    assert loads("0.1") == Fraction(1, 10)
    assert loads("-1.5e1") == -15
    assert loads("1e-400") == Fraction(1, 10**400)
    assert loads("1e400") == 10**400
    assert loads("-0") == 0 and type(loads("-0")) is int
    assert loads("0.0003") * 10000 == 3


def test_booleans_are_not_numbers():
    assert type(loads("true")) is bool
    assert type(loads("1")) is int


def test_strings_and_escapes():
    assert loads(r'"a\nb\t\"\\\/"') == 'a\nb\t"\\/'
    assert loads(r'"é"') == "é"
    assert loads(r'"💩"') == "\U0001F4A9"
    assert len(loads('"\U0001F4A9"')) == 1


def test_containers_keep_order():
    value = loads('{"b": 1, "a": [1, 2, {"c": null}], "e": {}}')
    assert list(value) == ["b", "a", "e"]
    assert value["a"][2] == {"c": None}
    assert loads("[]") == [] and loads("{}") == {}


def test_bom_is_ignored():
    assert loads("﻿[1]") == [1]


@pytest.mark.parametrize(
    "text",
    ["", "{", "[1,]", '{"a"}', "01", "1.", "-", "tru", '"abc', '"\\x"', "[1] x", '{"a":1,}', "1e"],
)
def test_malformed_input_is_rejected(text):
    with pytest.raises(JSONParseError):
        loads(text)


def test_deep_nesting():
    depth = 200
    value = loads("[" * depth + "]" * depth)
    for _ in range(depth - 1):
        value = value[0]
    assert value == []
