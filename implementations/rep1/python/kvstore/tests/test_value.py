import pytest

from tessera import TesseraError, render
from tessera.value import (MISSING, deep_equal, depth, deserialize, get_path, normalize_path,
                           rank, serialize, set_path, unset_path)


def test_serialization_examples():
    assert serialize(1) == bytes.fromhex("030000000000000001")
    assert serialize(-1) == bytes.fromhex("03ffffffffffffffff")
    assert serialize(None) == b"\x00"
    assert serialize(True) == b"\x02" and serialize(False) == b"\x01"
    assert serialize("") == bytes.fromhex("0400000000")
    assert serialize("ada") == bytes.fromhex("040000000361 6461".replace(" ", ""))
    assert len(serialize([1, "x", None])) == 21
    doc = {"name": "ada", "age": 36, "ok": True}
    data = serialize(doc)
    assert len(data) == 44
    assert data[:5] == bytes.fromhex("0600000003")
    assert data[5:12] == bytes.fromhex("00000003616765")   # fields sorted: age first
    assert serialize({"b": 1, "a": 2}) == serialize({"a": 2, "b": 1})


@pytest.mark.parametrize("doc", [
    None, True, False, 0, -2**63, 2**63 - 1, "", "é😀\x00", [], {}, [1, [2, [3]]],
    {"a": {"b": [None, "x"]}, "é": 1},
])
def test_roundtrip(doc):
    assert deserialize(serialize(doc)) == doc


def test_int_out_of_range_rejected():
    with pytest.raises(TesseraError) as e:
        serialize(2**63)
    assert e.value.kind == "int-range"


def test_render():
    assert render({"name": "ada", "age": 36}) == '{"age":36,"name":"ada"}'
    assert render([1, "x", None, True]) == '[1,"x",null,true]'
    assert render({}) == "{}" and render([]) == "[]"
    assert render(-2**63) == "-9223372036854775808"
    assert render('a"b\\c/\x08\t\n\x0c\r\x00\x1f\x7f é😀') == '"a\\"b\\\\c/\\b\\t\\n\\f\\r\\u0000\\u001f\\u007f é😀"'


def test_depth():
    assert depth(1) == 1 and depth([]) == 1 and depth({}) == 1
    assert depth([[]]) == 2
    assert depth({"a": [1, {"b": 2}]}) == 4


def test_kinds_are_never_equal_across_ranks():
    assert rank(True) == 1 and rank(1) == 2
    assert not deep_equal(True, 1)
    assert not deep_equal([True], [1])
    assert deep_equal({"a": [1, "x"]}, {"a": [1, "x"]})
    assert not deep_equal({"a": 1}, {"a": 1, "b": 2})


def test_paths():
    doc = {"a": {"b": 1}, "l": [1]}
    assert get_path(doc, ("a", "b")) == 1
    assert get_path(doc, ("a", "c")) is MISSING
    assert get_path(doc, ("l", "x")) is MISSING          # lists are never traversed
    assert get_path(5, ("a",)) is MISSING
    assert set_path(doc, ("a", "c", "d"), 2)["a"] == {"b": 1, "c": {"d": 2}}
    assert doc == {"a": {"b": 1}, "l": [1]}              # the input is not modified
    with pytest.raises(TesseraError) as e:
        set_path(doc, ("a", "b", "x"), 1)
    assert e.value.kind == "not-object"
    assert unset_path({"a": {"b": 1}}, ("a", "b")) == {"a": {}}
    with pytest.raises(TesseraError) as e:
        unset_path(doc, ("zz",))
    assert e.value.kind == "no-field"
    with pytest.raises(TesseraError) as e:
        unset_path(doc, ("a", "b", "c"))
    assert e.value.kind == "not-object"


def test_normalize_path():
    assert normalize_path("a.b") == ("a", "b")
    for bad in ["", "a." , "1a", "a." * 9 + "a", "x" * 31]:
        with pytest.raises(TesseraError) as e:
            normalize_path(bad)
        assert e.value.kind == "bad-path"
