import pytest

from jtemplate.errors import TemplateTypeError, UndefinedValueError
from jtemplate.values import UNDEFINED, sequence_view, to_repr, to_str, truthy


@pytest.mark.parametrize(
    "value, text",
    [
        (3, "3"),
        (-3, "-3"),
        (True, "True"),
        (False, "False"),
        (None, "None"),
        ("s", "s"),
        (3.0, "3.0"),
        (0.5, "0.5"),
        (1e15, "1000000000000000.0"),
        (1e16, "1e+16"),
        (1e-5, "1e-05"),
        (0.0001, "0.0001"),
        (0.1 + 0.2, "0.30000000000000004"),
        (-0.0, "-0.0"),
        (1.5e300, "1.5e+300"),
        ([], "[]"),
        ({}, "{}"),
        ([1, "a", True, None, 1.5, "it's", {"k": [2.0]}], "[1, 'a', True, None, 1.5, \"it's\", {'k': [2.0]}]"),
        (["a\nb\t\\", "'\""], ["['a\\nb\\t\\\\', '\\'\"']"][0]),
    ],
)
def test_to_str(value, text):
    assert to_str(value) == text


def test_repr_quotes():
    assert to_repr("x") == "'x'"
    assert to_repr("it's") == '"it\'s"'
    assert to_repr('say "hi"') == "'say \"hi\"'"


def test_undefined_cannot_be_printed_or_tested():
    with pytest.raises(UndefinedValueError):
        to_str(UNDEFINED)
    with pytest.raises(UndefinedValueError):
        truthy(UNDEFINED)


def test_truthiness():
    for falsy in (False, None, 0, 0.0, "", [], {}):
        assert truthy(falsy) is False
    for yes in (True, 1, 0.5, "0", [0], {"a": 1}):
        assert truthy(yes) is True


def test_sequence_view():
    assert sequence_view([1, 2]) == [1, 2]
    assert sequence_view({"b": 1, "a": 2}) == ["b", "a"]
    assert sequence_view("ab") == ["a", "b"]
    with pytest.raises(TemplateTypeError):
        sequence_view(5)
    with pytest.raises(UndefinedValueError):
        sequence_view(UNDEFINED)
