import pytest

from jqlite import JSONDecodeError, dumps, loads


def test_scalars():
    assert loads(" 1.5 ") == 1.5
    assert loads("null") is None
    assert loads("true") is True
    assert loads('"a"') == "a"


def test_numbers_are_floats():
    assert type(loads("3")) is float
    assert loads("0.1") == 0.1
    assert loads("-12") == -12.0
    assert loads("1e2") == 100.0


def test_string_escapes():
    assert loads(r'"a\"b\\c\/d\b\f\n\r\t"') == 'a"b\\c/d\b\f\n\r\t'
    assert loads(r'"éé"') == "éé"
    assert loads(r'"😀"') == "\U0001f600"
    assert loads(r'"\\u0041"') == "\\u0041"


def test_raw_utf8_passes_through():
    assert loads('"é😀"') == "é😀"


def test_object_keeps_document_order():
    assert list(loads('{"b":1,"a":2,"c":{"z":0,"y":1}}')) == ["b", "a", "c"]


def test_nested():
    assert loads('[1, [2, {"a": []}], {}]') == [1.0, [2.0, {"a": []}], {}]


@pytest.mark.parametrize("bad", ["", "[1,", "{\"a\"}", "[1 2]", "tru", "1 2", '"abc', "{1:2}"])
def test_malformed(bad):
    with pytest.raises(JSONDecodeError):
        loads(bad)


def test_dump_compact():
    assert dumps(loads('{ "a" : [1, 2.5, "x", null, true, false, {}, []] }')) == \
        '{"a":[1,2.5,"x",null,true,false,{},[]]}'


def test_dump_string_escapes():
    assert dumps("a\"\\\b\f\n\r\t\x01\x7f/é<>&") == '"a\\"\\\\\\b\\f\\n\\r\\t\\u0001\\u007f/é<>&"'


def test_dump_numbers():
    assert dumps(3.0) == "3"
    assert dumps(-12.0) == "-12"
    assert dumps(1000000000000.0) == "1000000000000"
    assert dumps(0.125) == "0.125"
    assert dumps(3086419725308.5) == "3086419725308.5"
    assert dumps(0.1 + 0.2) == "0.30000000000000004"


def test_roundtrip():
    text = '{"k":[1,2.5,{"é":"\\n"}],"z":null}'
    assert dumps(loads(text)) == text


def test_deep_nesting():
    text = "[" * 64 + "]" * 64
    assert dumps(loads(text)) == text
