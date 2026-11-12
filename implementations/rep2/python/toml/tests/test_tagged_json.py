import pytest

import tomlcodec
from tomlcodec import Array, Scalar, Table, TaggedJsonError, from_tagged_json, to_tagged_json


def test_keys_sorted_by_code_point():
    t = Table({"é": Scalar("bool", "true"), "a": Scalar("bool", "true"),
               "A": Scalar("bool", "true"), "": Scalar("bool", "true")})
    out = to_tagged_json(t)
    keys = [out.index(f'"{k}":') for k in ("", "A", "a", "é")]
    assert keys == sorted(keys)


def test_array_order_is_preserved():
    t = tomlcodec.loads("a = [3, 1, 2]")
    assert to_tagged_json(t).count("3") == 1
    assert to_tagged_json(t).index('"3"') < to_tagged_json(t).index('"1"')


def test_string_escaping():
    t = Table({"s": Scalar("string", '"\\\b\f\n\r\t\x00\x1f\x7f é😀')})
    assert to_tagged_json(t) == (
        '{"s":{"type":"string","value":"\\"\\\\\\b\\f\\n\\r\\t\\u0000\\u001f\x7f é😀"}}'
    )


def test_reader_accepts_any_member_order_and_whitespace():
    text = '{"b" : [ {"type":"integer","value":"1"} ] , "a":{"value":"x","type":"string"}}'
    t = from_tagged_json(text)
    assert isinstance(t["b"], Array)
    assert t["a"] == Scalar("string", "x")
    assert to_tagged_json(t) == (
        '{"a":{"type":"string","value":"x"},"b":[{"type":"integer","value":"1"}]}'
    )


def test_table_named_type_and_value():
    t = from_tagged_json(
        '{"type":{"type":"string","value":"a"},"value":{"type":"string","value":"b"}}'
    )
    assert isinstance(t, Table)
    assert set(t) == {"type", "value"}


@pytest.mark.parametrize("bad", ["[]", "3", "{", '{"a": 1}', '{"a": null}'])
def test_rejects_malformed(bad):
    with pytest.raises(TaggedJsonError):
        from_tagged_json(bad)
