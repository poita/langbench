import pytest

from jtemplate import operators as op
from jtemplate.errors import TemplateTypeError, UndefinedValueError
from jtemplate.values import UNDEFINED


def test_arithmetic():
    assert op.add(1, 2) == 3 and op.add("a", "b") == "ab" and op.add([1], [2]) == [1, 2]
    assert op.div(6, 3) == 2.0 and isinstance(op.div(6, 3), float)
    assert op.floordiv(-7, 2) == -4 and op.floordiv(7.0, 2) == 3.0
    assert op.mod(-7, 3) == 2 and op.mod(7, -3) == -2
    assert op.power(2, 10) == 1024 and op.power(2, -1) == 0.5
    assert op.mul("ab", 2) == "abab" and op.mul(2, "ab") == "abab" and op.mul("a", -1) == ""
    assert op.power(-2, 2) == 4


def test_booleans_are_integers():
    assert op.add(True, True) == 2
    assert op.equal(True, 1) and op.equal(1, 1.0)


def test_equality_never_raises_type_error():
    assert not op.equal(1, "1") and not op.equal(None, 0)
    assert op.equal([1, "a"], [1.0, "a"]) and op.equal({"a": 1, "b": 2}, {"b": 2, "a": 1})
    assert op.equal(None, None)


@pytest.mark.parametrize(
    "fn, a, b",
    [
        (op.add, 1, "a"),
        (op.sub, "a", "b"),
        (op.mul, [1], 2),
        (op.div, 1, 0),
        (op.floordiv, 1, 0.0),
        (op.mod, 1, 0),
        (op.power, 0, -1),
        (op.less, 1, "a"),
        (op.less, [1], [2]),
        (op.contains, 1, "abc"),
        (op.contains, 1, 5),
    ],
)
def test_type_errors(fn, a, b):
    with pytest.raises(TemplateTypeError):
        fn(a, b)


@pytest.mark.parametrize("fn", [op.add, op.equal, op.less, op.contains, op.concat])
def test_undefined_operand(fn):
    with pytest.raises(UndefinedValueError):
        fn(UNDEFINED, 1)
    with pytest.raises(UndefinedValueError):
        fn(1, UNDEFINED)


def test_ordering_and_contains():
    assert op.less("ab", "abc") and op.greater_equal(2, 2.0)
    assert op.contains("", "abc") and op.contains("b", "abc")
    assert op.contains("a", {"a": 1}) and not op.contains(1, {"a": 1})
    assert op.contains(1, [True]) and op.not_contains(2, [1])


def test_concat_uses_printing():
    assert op.concat(1, True) == "1True"
    assert op.concat([1, "a"], None) == "[1, 'a']None"
