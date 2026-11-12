"""End-to-end scenarios run through :func:`cardgame.run_match`."""

from cardgame import run_match

HEAD = ("1 GAME-START A\n2 TURN 1 A\n3 PHASE dawn\n4 EMBER A 1 1\n"
        "5 EMBER B 0 0\n6 PHASE draw\n7 PHASE main1\n")


def lines(text):
    return text.splitlines()


def test_fatal_errors(tmp_path, db_path):
    assert run_match("SEED 1\nSTART\n") == "FATAL bad-setup\n"
    out = run_match("CARDS /nonexistent.spire\nSEED 1\nSTART\n")
    assert out == "FATAL bad-database\n"
    out = run_match("CARDS %s\nSEED 1\nDECK A ZZZ-999\nSTART\n" % db_path)
    assert out == "FATAL unknown-card\n"


def test_pending_result_and_header(match):
    out = run_match(match())
    assert out == HEAD + "8 RESULT pending none\n"


def test_bolt_wins_on_spire(match):
    out = run_match(match("SPIRE 2\nHAND A TST-002\nDECK A TST-001\n"
                          "DECK B TST-001",
                          "A PLAY 1 B\nA PASS\nB PASS\nA PASS"))
    assert lines(out)[7:] == [
        "8 PLAY A ~1 #2 TST-002 B", "9 PAY A ember 1", "10 PASS A",
        "11 PASS B", "12 RESOLVE ~1", "13 DAMAGE #2 B 2", "14 SPIRE B -2 0",
        "15 SPENT #2 TST-002", "16 LOSE B spire", "17 RESULT A spire",
        "ERR 13 game-over"]


def test_error_precedence(match):
    out = run_match(match("HAND A TST-002 TST-007\nDECK A TST-001\n"
                          "DECK B TST-001",
                          "X PASS\nB PASS\nA BLOCK\nA PLAY 5\nA PLAY 1\n"
                          "A PLAY 1 #99\nA PLAY 2 #1\nDUMP x"))
    errs = [l for l in lines(out) if l.startswith("ERR")]
    assert [e.split()[2] for e in errs] == [
        "bad-syntax", "not-your-turn", "wrong-decision", "no-such-card",
        "bad-target-count", "illegal-target", "illegal-target", "bad-syntax"]
    first = int(errs[0].split()[1])
    assert [int(e.split()[1]) for e in errs] == list(range(first, first + 8))


def test_aura_modifies_whole_board(match):
    out = run_match(match("FIELD A TST-004 TST-001", "DUMP"))
    assert "field A #2 TST-001 3/1 w0 c0 ready - kw vanguard" in out
    assert "effect 1 ts2 A aura modify 1 0 on #2" in out


def test_tenacity_replaces_one_destruction(match):
    out = run_match(match(
        "CAP A 4\nHAND A TST-007 TST-007\nDECK A TST-001\nDECK B TST-001\n"
        "FIELD B TST-005",
        "A PLAY 1 #5\nA PASS\nB PASS\nA PLAY 1 #5\nA PASS\nB PASS"))
    assert "TENACITY #5" in out
    assert "DESTROY #5 TST-005" in out
    assert out.index("TENACITY") < out.index("DESTROY")


def test_riposte_fights_first(match):
    out = run_match(match(
        "DECK A TST-001\nDECK B TST-001\nFIELD A TST-006\nFIELD B TST-001",
        "A PASS\nB PASS\nA ATTACK #2\nA PASS\nB PASS\nB BLOCK #4:#2\n"
        "A PASS\nB PASS"))
    body = lines(out)
    assert any(l.endswith("PHASE clash-riposte") for l in body)
    assert any(l.endswith("DESTROY #4 TST-001") for l in body)


def test_activated_ability_and_legal(match):
    out = run_match(match("CAP A 2\nFIELD A TST-008\nDECK A TST-001\n"
                          "DECK B TST-001", "LEGAL"))
    assert "ACT #2 1" in out
    assert "PASS" in lines(out)


def test_concede_and_trace(match):
    out = run_match(match("TRACE state", "A CONCEDE\nB PASS"))
    assert "LOSE A concede" in out
    assert "RESULT B concede" in out
    assert "decision - over" in out
    assert lines(out)[-1].endswith("game-over")


def test_turn_limit_draw(match):
    text = match("TURNLIMIT 1\nDECK A TST-001*5\nDECK B TST-001*5")
    passes = "\n".join(["A PASS", "B PASS"] * 4 + ["A ATTACK"]
                        + ["A PASS", "B PASS"] * 4)
    out = run_match(text + passes + "\nDUMP\n")
    assert "RESULT draw turn-limit" in out
    assert "turn 2 active B phase dusk-cleanup decision - over" in out


def test_vault_empty_draw_loses(match):
    out = run_match(match("OPENING 1\nDECK A TST-001", ""))
    assert "DRAW-EMPTY B" in out
    assert out.rstrip().endswith("RESULT A vault")


def test_card_directive(match):
    out = run_match(match("", "CARD TST-002\nCARD NOPE-1"))
    assert ("ability 1 resolve (targets (any)) (damage 2 (t 1))\n"
            "CARD END") in out
    assert "CARD BEGIN NOPE-1\nunknown\nCARD END" in out


def test_shuffle_uses_seeded_prng(match):
    text = match("SHUFFLE on\nDECK A TST-001*8", "VAULT").replace(
        "SHUFFLE off\n", "")
    first = run_match(text)
    assert first == run_match(text)
    assert "SHUFFLE A" in first and "SHUFFLE B" in first
