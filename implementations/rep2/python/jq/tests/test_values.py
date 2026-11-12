import pytest

from jqlite import Obj, compare, equals, from_native, loads, sort_key, to_native, type_name


def j(text):
    return loads(text)


def test_type_order():
    vals = [j(t) for t in ["null", "false", "true", "0", '""', "[]", "{}"]]
    for a, b in zip(vals, vals[1:]):
        assert compare(a, b) == -1
        assert compare(b, a) == 1


def test_strings_by_code_point():
    assert compare("Z", "a") < 0
    assert compare("z", "é") < 0
    assert compare("a", "ab") < 0
    assert compare("", "a") < 0


def test_arrays_lexicographic():
    assert compare(j("[1,2]"), j("[1,2,0]")) < 0
    assert compare(j("[2]"), j("[1,9]")) > 0


def test_objects():
    # sorted key lists first, then values in key order
    assert compare(j('{"a":2}'), j('{"b":1}')) < 0
    assert compare(j('{"a":1,"b":2}'), j('{"a":1,"c":0}')) < 0
    assert compare(j('{"a":1,"b":2}'), j('{"a":2,"b":1}')) < 0


def test_equality_ignores_key_order_and_number_kind():
    assert equals(j('{"a":1,"b":2}'), j('{"b":2,"a":1.0}'))
    assert not equals(True, 1.0)
    assert not equals(False, None)
    assert equals(1.0, 1.5 - 0.5)


def test_sorted_keys_cached():
    o = j('{"b":1,"a":2}')
    assert o.sorted_keys() is o.sorted_keys()
    assert o.sorted_keys() == ("a", "b")


def test_native_conversion():
    v = from_native({"a": [1, 2.5, None, True, "x"]})
    assert type(v) is Obj and v["a"][0] == 1.0 and type(v["a"][0]) is float
    assert to_native(v) == {"a": [1, 2.5, None, True, "x"]}
    with pytest.raises(TypeError):
        from_native({1: 2})


def test_type_name():
    assert [type_name(j(t)) for t in ["null", "true", "1", '"s"', "[]", "{}"]] == [
        "null", "boolean", "number", "string", "array", "object",
    ]


def test_sort_key_rejects_foreign():
    with pytest.raises(TypeError):
        sort_key(object())
