import pytest

from jqlite import JSONDecodeError, dumps, loads
from jqlite.values import Obj


def test_scalars():
    assert loads("null") is None
    assert loads(" true ") is True
    assert loads("false") is False
    assert loads("-12.5") == -12.5
    assert type(loads("3")) is float
    assert loads('"abc"') == "abc"


def test_string_escapes():
    assert loads(r'"a\"b\\c\/d\b\f\n\r\t"') == 'a"b\\c/d\b\f\n\r\t'
    assert loads(r'"éé"') == "éé"
    assert loads(r'"😀"') == "\U0001F600"
    assert loads('"héllo 😀"') == "héllo 😀"


def test_containers_keep_order():
    v = loads('{"z":1,"a":[1,2,{"q":null}],"m":{}}')
    assert type(v) is Obj
    assert list(v) == ["z", "a", "m"]
    assert v["a"][2]["q"] is None
    assert loads("[ ]") == [] and loads("{ }") == {}


def test_whitespace_only_tab_lf_cr_space():
    assert loads("\t\r\n [1 ,\n2]\r\n") == [1.0, 2.0]


def test_deep_nesting_does_not_recurse():
    depth = 5000
    v = loads("[" * depth + "]" * depth)
    for _ in range(depth - 1):
        v = v[0]
    assert v == []


@pytest.mark.parametrize(
    "bad", ["", "[1,]", "{", '{"a"}', "[1 2]", "tru", "01", '"a', "[1]x", '{"a":1,}', "[}", '"\\x"']
)
def test_invalid(bad):
    with pytest.raises(JSONDecodeError):
        loads(bad)


@pytest.mark.parametrize(
    "text",
    [
        "null", "true", "[]", "{}", "[1,2.5,-3]", '{"b":1,"a":[null,false]}',
        '"a\\"b\\\\c\\n\\t\\u0001\\u007f"', '"é😀/<>&"', "3086419725308.5", "0.125", "1000000000000",
    ],
)
def test_roundtrip(text):
    assert dumps(loads(text)) == text


def test_number_formatting():
    assert dumps(3.0) == "3"
    assert dumps(-12.0) == "-12"
    assert dumps(0.1) == "0.1"
    assert dumps(1.5) == "1.5"
    assert dumps(-0.0) == "-0"


def test_string_escape_output():
    assert dumps("\x08\x0c\x0a\x0d\x09\x1f\x7f/") == '"\\b\\f\\n\\r\\t\\u001f\\u007f/"'
