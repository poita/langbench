import pytest

from jsoncanon import JSONError, canonicalize, dumps, parse
from jsoncanon.serializer import quote


@pytest.mark.parametrize(
    "doc,out",
    [
        (b'{ "b": [1, 2.50, 1E+3], "a": "h\xc3\xa9llo\\/", "b": null }',
         '{"a":"h\u00e9llo/","b":null}'),
        ('["\U0001f600", -0, 1e-007, 0.0, 1e-0, "tab\\tquote\\"nul\\u0000 A\\u0041"]'.encode(),
         '["\U0001f600",-0,1e-7,0.0,1e0,"tab\\tquote\\"nul\\u0000 AA"]'),
        (b'"\\u007f\\/\\u2028\\uD83D\\uDE00"', '"\x7f/\u2028\U0001f600"'),
        (b"[]", "[]"), (b"{}", "{}"), (b"[ [ ] , { } ]", "[[],{}]"),
        (b'{"a":{"b":[true,false,null]}}', '{"a":{"b":[true,false,null]}}'),
        (b'"\\b\\f\\n\\r\\t\\u001f\\u0001\\\\"', '"\\b\\f\\n\\r\\t\\u001f\\u0001\\\\"'),
    ],
)
def test_examples(doc, out):
    assert canonicalize(doc) == out.encode()


def test_utf16_key_order():
    doc = '{"\\uE000":1,"\U0001f600":2,"\\uFFFF":3,"Z":4}'.encode()
    assert canonicalize(doc).decode() == '{"Z":4,"\U0001f600":2,"\ue000":1,"\uffff":3}'


def test_prefix_and_misc_order():
    doc = '{"aa":1,"a\\u0000":2,"\u00e9":3,"":4,"a":5,"Z":6}'.encode()
    assert canonicalize(doc).decode() == '{"":4,"Z":6,"a":5,"a\\u0000":2,"aa":1,"\u00e9":3}'


def test_duplicates_by_decoded_value_last_wins():
    assert canonicalize(b'{"a":1,"\\u0061":2,"b":0,"a":3}') == b'{"a":3,"b":0}'
    assert canonicalize(b'{"a":1,"a":{"x":1,"x":2}}') == b'{"a":{"x":2}}'


def test_idempotent():
    doc = b'{"z":[1.0e+10,{"b":1,"a":2}],"y":"\\u00e9"}'
    once = canonicalize(doc)
    assert canonicalize(once) == once


def test_deep_nesting_serializes():
    doc = b"[" * 512 + b"]" * 512
    assert canonicalize(doc) == doc


def test_invalid_raises():
    with pytest.raises(JSONError):
        canonicalize(b"[1,]")


def test_quote():
    assert quote('a"b\\c\x7f/') == '"a\\"b\\\\c\x7f/"'


def test_dumps_rejects_foreign_types():
    with pytest.raises(TypeError):
        dumps({"a": 1})


def test_large_object_sort():
    n = 20000
    doc = ("{" + ",".join(f'"k{i * 7919 % n}":{i}' for i in range(n)) + "}").encode()
    out = canonicalize(doc).decode()
    keys = list(parse(out.encode()).members)
    assert [k for k, _ in keys] == sorted(f"k{i}" for i in range(n))
