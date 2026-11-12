import pytest

from cardgame.database import parse_database
from cardgame.errors import DatabaseError


def test_mini_database_loads(db_path):
    from cardgame import load_database
    db = load_database(db_path)
    assert len(db) == 8
    bolt = db.get("TST-002")
    assert bolt.type == "rite" and bolt.is_swift
    assert [a.kind for a in db.get("TST-008").abilities] == ["act"]


def test_ability_numbering_order():
    db = parse_database("""
    (card AAA-001 (name "x") (type unit) (cost 0) (body 1 1)
      (aura (modify 1 1 self))
      (act (cost (once)) (draw 1 you))
      (on arrive (draw 1 you))
      (on dies (draw 1 you)))""")
    kinds = [(a.number, a.kind) for a in db.get("AAA-001").abilities]
    assert kinds == [(1, "on"), (2, "on"), (3, "act"), (4, "aura")]


def test_empty_database_is_valid():
    assert len(parse_database("; nothing\n")) == 0


UNIT = '(card AAA-001 (name "x") (type unit) (cost 0) (body 1 1) %s)'
RITE = '(card AAA-001 (name "x") (type rite) (cost 1) %s)'


@pytest.mark.parametrize("text", [
    "(deck AAA-001)",
    "stray",
    '(card aaa-001 (name "x") (type unit) (cost 0) (body 1 1))',
    UNIT % '(keywords swift)',
    UNIT % '(keywords plating)',
    UNIT % '(keywords nonsense)',
    UNIT % '(act (draw 1 you))',
    UNIT % '(act (cost (ember 1)))',
    UNIT % '(act (cost (tap)) (draw 1 you))',
    UNIT % '(on sunrise (draw 1 you))',
    UNIT % '(aura)',
    UNIT % '(aura (destroy (units theirs)))',
    UNIT % '(text "a") (text "b")',
    UNIT % '(name "again")',
    RITE % '',
    RITE % '(resolve)',
    RITE % '(resolve (damage 1 foe) (targets (unit)))',
    RITE % '(resolve (draw 1 everyone))',
    RITE % '(resolve (destroy (units mine)))',
    RITE % '(resolve (damage 2 (units theirs (cost gte 2))))',
    RITE % '(resolve (if (myturn) (draw 1 you)))',
    RITE % '(resolve (negate self))',
    RITE % '(resolve (summon AAA-404 1 you))',
    RITE % '(resolve (summon AAA-001 1 you))',
    RITE % '(resolve (delay sunset (draw 1 you)))',
    RITE % '(resolve (draw 1))',
])
def test_invalid(text):
    with pytest.raises(DatabaseError):
        parse_database(text)


def test_duplicate_ids_rejected():
    one = '(card AAA-001 (name "x") (type relic) (cost 0))'
    with pytest.raises(DatabaseError):
        parse_database(one + one)


def test_conjure_and_summon_need_known_cards():
    ok = parse_database(
        '(card AAA-001 (name "x") (type unit) (cost 0) (body 1 1))'
        '(card AAA-002 (name "y") (type rite) (cost 0)'
        ' (resolve (summon AAA-001 1 you) (conjure AAA-002 1 you)))')
    assert len(ok) == 2
