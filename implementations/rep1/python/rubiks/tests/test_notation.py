import pytest

from rubiks import format_moves, invert_moves, parse_moves
from rubiks.notation import invert_move


def test_parse():
    assert parse_moves("") == []
    assert parse_moves("R U' F2") == ["R", "U'", "F2"]


@pytest.mark.parametrize("bad", ["r", "R2'", "R'2", "X", "R3"])
def test_parse_rejects_bad_tokens(bad):
    with pytest.raises(ValueError):
        parse_moves(bad)


def test_format():
    assert format_moves(["R", "U'"]) == "R U'"
    assert format_moves([]) == ""


def test_invert():
    assert invert_move("R") == "R'"
    assert invert_move("R'") == "R"
    assert invert_move("R2") == "R2"
    assert invert_moves(["R", "U'", "F2"]) == ["F2", "U", "R'"]
