import pytest

from svgraster.colors import CURRENT, NAMED_COLORS, NONE, parse_color
from svgraster.values import parse_length, parse_number_list, parse_opacity, parse_style


@pytest.mark.parametrize("text,expected", [
    ("5", 5.0), (".5", 0.5), ("5.", 5.0), ("-1e2", -100.0), (" 3px ", 3.0),
    ("1e", 1.0), ("abc", None), ("", None), ("px", None),
])
def test_parse_length(text, expected):
    assert parse_length(text) == expected


def test_number_list():
    assert parse_number_list("1,2 3-4 .5.5 1e1") == [1, 2, 3, -4, 0.5, 0.5, 10]
    assert parse_number_list("1 2 x 3") == [1, 2]


@pytest.mark.parametrize("text,expected", [
    ("0.5", 0.5), ("50%", 0.5), ("2", 1.0), ("-1", 0.0), ("0.5x", None), ("x", None),
])
def test_parse_opacity(text, expected):
    assert parse_opacity(text) == expected


def test_parse_style():
    assert parse_style("a:b;;C : d ; e; f:; g:h;") == {"a": "b", "c": "d", "g": "h"}


@pytest.mark.parametrize("text,expected", [
    ("#f39", (255, 51, 153)), ("#FF3399", (255, 51, 153)), ("RED", (255, 0, 0)),
    ("rgb(10%, 50%, 100%)", (26, 128, 255)), ("rgb(300 -4 127.5)", (255, 0, 128)),
    ("none", NONE), ("CurrentColor", CURRENT), ("#12", None), ("bogus", None),
])
def test_parse_color(text, expected):
    assert parse_color(text) == expected


def test_color_table_size():
    assert len(NAMED_COLORS) == 147
    assert NAMED_COLORS["yellowgreen"] == (154, 205, 50)
