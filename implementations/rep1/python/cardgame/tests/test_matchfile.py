import pytest

from cardgame.errors import SetupError
from cardgame.matchfile import parse_script_line, parse_setup, split_lines

BASE = ["CARDS data/cards.spire", "SEED 1"]


def setup(*extra):
    return parse_setup(BASE + list(extra) + ["START"])


def test_defaults_and_overrides():
    cfg, start = setup("SPIRE 7", "FIRST B", "CAP A 3", "DECK A X-1*3 Y-2")
    assert (cfg.spire, cfg.first, cfg.cap["A"], cfg.opening) == (7, "B", 3, 5)
    assert cfg.zones["DECK"]["A"] == [("X-1", 3), ("Y-2", 1)]
    assert start == 7


def test_comments_are_ignored():
    cfg, _ = parse_setup(["# c", "  ", *BASE, "\t# d", "START"])
    assert cfg.seed == 1


@pytest.mark.parametrize("line", [
    "SPIRE 0", "SPIRE 1000001", "SPIRE +5", "SPIRE x", "OPENING 21",
    "SEED -1", "SEED 18446744073709551616", "FIRST C", "SHUFFLE maybe",
    "TRACE all", "BOGUS 1", "DECK A", "DECK C X-1", "DECK A X-1*0",
    "DECK A X-1*1001", "DECK A *2", "CAP A 101", "HANDMAX 101",
    "MAXCAP 0", "TURNLIMIT 0",
])
def test_bad_setup_lines(line):
    with pytest.raises(SetupError) as exc:
        setup(line)
    assert exc.value.kind == "bad-setup"


@pytest.mark.parametrize("lines", [
    ["SEED 1", "START"],
    ["CARDS a", "START"],
    ["CARDS a", "SEED 1"],
    ["CARDS a", "SEED 1", "SEED 2", "START"],
    ["CARDS a", "SEED 1", "START now"],
])
def test_structural_setup_errors(lines):
    with pytest.raises(SetupError):
        parse_setup(lines)


def test_cap_lines_are_separate_single_use():
    setup("CAP A 1", "CAP B 2")
    with pytest.raises(SetupError):
        setup("CAP A 1", "CAP A 2")


def test_split_lines_strips_cr():
    assert split_lines("a\r\nb\n\nc") == ["a", "b", "", "c"]


def test_script_actions():
    cmd = parse_script_line("A PLAY 2 #007 B ~3")
    a = cmd.action
    assert (a.kind, a.pos, a.targets) == (
        "PLAY", 2, (("O", 7), ("P", "B"), ("E", 3)))
    assert parse_script_line("B BLOCK #4:#2 #5:#2").action.pairs == (
        (4, 2), (5, 2))
    assert parse_script_line("A ACT #3 1 A").action.index == 1
    assert parse_script_line("A ATTACK").action.objs == ()
    assert parse_script_line("CARD ABC-123").card_id == "ABC-123"


def test_script_syntax_errors_and_comments():
    assert parse_script_line("# hi") is False
    assert parse_script_line("   ") is False
    for bad in ["X PASS", "A", "A PASS now", "A PLAY", "A PLAY x",
                "A PLAY 99999999999999999999", "A ACT 3 1", "A BLOCK #1",
                "A ATTACK 3", "DUMP x", "CARD", "CARD a b", "A PLAY 1 Z"]:
        assert parse_script_line(bad) is None, bad
