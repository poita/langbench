from jqlite import Obj, from_python, loads, sort_key, to_python
from jqlite.values import compare, equal, is_true, type_name


def ordered(*texts):
    vals = [loads(t) for t in texts]
    return sorted(vals, key=sort_key)


def test_type_order():
    texts = ['{}', '[]', '"a"', '1', 'true', 'false', 'null']
    assert ordered(*texts) == [loads(t) for t in reversed(texts)]


def test_string_order_is_code_point_order():
    assert ordered('"é"', '"z"', '"Z"', '"ab"', '"a"', '""') == \
        ["", "Z", "a", "ab", "z", "é"]
    assert compare("\U0001f600", "￿") == 1  # astral after BMP


def test_array_order():
    assert ordered("[1,2]", "[1]", "[0,9]") == [[0.0, 9.0], [1.0], [1.0, 2.0]]


def test_object_order():
    a, b, c = loads('{"a":2}'), loads('{"a":1,"b":0}'), loads('{"b":0}')
    assert sorted([b, c, a], key=sort_key) == [a, b, c]
    assert compare(loads('{"a":1}'), loads('{"a":2}')) == -1


def test_equality_ignores_key_order_and_number_kind():
    assert equal(loads('{"a":1,"b":2}'), loads('{"b":2,"a":1}'))
    assert equal(1.0, 1.5 - 0.5)
    assert not equal(1.0, True)
    assert not equal([1.0], [1.0, 2.0])
    assert equal(0.0, -0.0)


def test_truthiness_and_type_names():
    assert [is_true(v) for v in (None, False, True, 0.0, "", [], Obj())] == \
        [False, False, True, True, True, True, True]
    assert [type_name(v) for v in (None, True, 1.0, "", [], Obj())] == \
        ["null", "boolean", "number", "string", "array", "object"]


def test_sorted_keys_cached():
    o = loads('{"b":1,"a":2}')
    first = o.sorted_keys()
    assert first == ["a", "b"]
    assert o.sorted_keys() is first


def test_python_conversion():
    v = from_python({"a": [1, 2.5, None, True]})
    assert type(v) is Obj and v["a"][0] == 1.0 and type(v["a"][0]) is float
    assert to_python(v) == {"a": [1, 2.5, None, True]}
