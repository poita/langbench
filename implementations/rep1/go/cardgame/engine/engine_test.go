package engine_test

import (
	"strings"
	"testing"

	"cardgame/cards"
	"cardgame/engine"
	"cardgame/match"
)

const testDB = `
(card TST-001 (name "Bolt") (type rite) (cost 1) (keywords swift)
  (resolve (targets (any)) (damage 2 (t 1))))
(card TST-002 (name "Grunt") (type unit) (cost 1) (body 2 2) (tags grunt))
(card TST-003 (name "Wall") (type unit) (cost 2) (body 0 4) (keywords (plating 1)))
(card TST-004 (name "Banner") (type relic) (cost 2) (aura (modify 1 1 (units yours))))
(card TST-005 (name "Seer") (type unit) (cost 2) (body 1 1) (on arrive (draw 1 you)))
(card TST-006 (name "Execute") (type rite) (cost 1) (resolve (targets (unit)) (destroy (t 1))))
(card TST-007 (name "Tough") (type unit) (cost 1) (body 1 1) (keywords tenacity))
(card TST-008 (name "Ghost") (type unit) (cost 1) (body 1 1) (keywords spectral))
(card TST-009 (name "Duelist") (type unit) (cost 1) (body 2 1) (keywords riposte))
(card TST-010 (name "Thief") (type rite) (cost 1) (resolve (targets (unit (enemy))) (control (t 1))))
(card TST-011 (name "Pinger") (type unit) (cost 1) (body 1 3)
  (act (cost (ember 1) (exhaust)) (targets (unit)) (damage 1 (t 1))))
(card TST-012 (name "Mourner") (type unit) (cost 1) (body 1 1) (on ally-dies (spire 1 you)))
`

func newGame(t *testing.T, setup ...string) *engine.Game {
	t.Helper()
	db, err := cards.Parse([]byte(testDB))
	if err != nil {
		t.Fatal(err)
	}
	src := "CARDS inline\nSEED 1\nOPENING 0\nSHUFFLE off\nSPIRE 10\n" + strings.Join(setup, "\n") + "\nSTART\n"
	f, err := match.ParseFile(src)
	if err != nil {
		t.Fatal(err)
	}
	g, err := engine.New(db, f.Setup)
	if err != nil {
		t.Fatal(err)
	}
	return g
}

// play feeds script lines to the game and returns the output so far.
func play(t *testing.T, g *engine.Game, lines ...string) string {
	t.Helper()
	for i, ln := range lines {
		cmd, err := match.ParseCommand(ln)
		if err != nil {
			g.Reject(i+1, "bad-syntax")
			continue
		}
		g.Exec(cmd, i+1)
	}
	return string(g.Output())
}

func mustContain(t *testing.T, out string, want ...string) {
	t.Helper()
	for _, w := range want {
		if !strings.Contains(out, w) {
			t.Errorf("output lacks %q:\n%s", w, out)
		}
	}
}

func TestUnknownCard(t *testing.T) {
	db, _ := cards.Parse([]byte(testDB))
	f, _ := match.ParseFile("CARDS x\nSEED 1\nDECK A ZZZ-999\nSTART\n")
	if _, err := engine.New(db, f.Setup); err != engine.ErrUnknownCard {
		t.Fatalf("got %v", err)
	}
}

func TestSetupEventsAndDump(t *testing.T) {
	g := newGame(t, "DECK A TST-002*2", "HAND A TST-001", "FIELD B TST-003")
	out := play(t, g, "DUMP")
	mustContain(t, out,
		"1 GAME-START A\n2 TURN 1 A\n3 PHASE dawn\n4 EMBER A 1 1\n5 EMBER B 0 0\n6 PHASE draw\n7 PHASE main1\n",
		"turn 1 active A phase main1 decision A priority",
		"player A spire 10 ember 1 cap 1 vault 2 hand 1 ash 0 rift 0",
		"hand A 1 #3 TST-001",
		"field B #4 TST-003 0/4 w0 c0 ready - kw plating:1")
}

func TestBoltKillsAndTriggers(t *testing.T) {
	g := newGame(t, "CAP A 3", "HAND A TST-001", "FIELD A TST-012", "FIELD B TST-002")
	out := play(t, g, "A PLAY 1 #3", "A PASS", "B PASS")
	mustContain(t, out,
		"PLAY A ~1 #1 TST-001 #3", "PAY A ember 1", "RESOLVE ~1", "DAMAGE #1 #3 2",
		"SPENT #1 TST-001", "DESTROY #3 TST-002")
}

func TestPlatingAndShieldPrevention(t *testing.T) {
	g := newGame(t, "CAP A 3", "HAND A TST-001", "FIELD B TST-003")
	out := play(t, g, "A PLAY 1 #2", "A PASS", "B PASS")
	mustContain(t, out, "PREVENT #2 1", "DAMAGE #1 #2 1")
}

func TestTenacityReplacesDestruction(t *testing.T) {
	g := newGame(t, "CAP A 4", "HAND A TST-006 TST-006", "FIELD B TST-007")
	out := play(t, g, "A PLAY 1 #3", "A PASS", "B PASS", "A PLAY 1 #3", "A PASS", "B PASS")
	if strings.Count(out, "TENACITY #3") != 1 || strings.Count(out, "DESTROY #3") != 1 {
		t.Errorf("tenacity should replace exactly one destruction:\n%s", out)
	}
	if strings.Index(out, "TENACITY") > strings.Index(out, "DESTROY") {
		t.Errorf("tenacity must come first:\n%s", out)
	}
}

func TestAuraDerivation(t *testing.T) {
	g := newGame(t, "FIELD A TST-004 TST-002", "FIELD B TST-002")
	out := play(t, g, "DUMP")
	mustContain(t, out,
		"field A #2 TST-002 3/3", "field B #3 TST-002 2/2",
		"effect 1 ts2 A aura modify 1 1 on #2")
}

func TestSpectralProtectsFromEnemyTargets(t *testing.T) {
	g := newGame(t, "CAP A 3", "HAND A TST-006", "FIELD B TST-008")
	out := play(t, g, "A PLAY 1 #2", "LEGAL")
	mustContain(t, out, "ERR 1 illegal-target", "LEGAL BEGIN A priority\nPASS\nLEGAL END")
}

func TestControlChangeTurnsUnitAround(t *testing.T) {
	g := newGame(t, "CAP A 3", "HAND A TST-010", "FIELD B TST-002")
	out := play(t, g, "A PLAY 1 #2", "A PASS", "B PASS", "DUMP")
	mustContain(t, out, "CONTROL #2 A", "field A #2 TST-002 2/2 w0 c0 ready settling kw -",
		"effect 1 ts2 A turn control A on #2")
}

func TestActivatedAbility(t *testing.T) {
	g := newGame(t, "CAP A 3", "FIELD A TST-011", "FIELD B TST-002")
	out := play(t, g, "A ACT #1 1 #2", "A PASS", "B PASS")
	mustContain(t, out, "ACTIVATE A ~1 #1 1 #2", "PAY A ember 1", "EXHAUST #1", "DAMAGE #1 #2 1")
	out = play(t, g, "A ACT #1 1 #2")
	mustContain(t, out, "cost-unpayable")
}

func TestErrorKinds(t *testing.T) {
	g := newGame(t, "HAND A TST-002 TST-001")
	out := play(t, g,
		"X PASS", "B PASS", "A BLOCK", "A PLAY 9", "A PLAY 1 A", "A PLAY 2", "A ACT #7 1", "A PLAY 2 #99")
	for i, want := range []string{"bad-syntax", "not-your-turn", "wrong-decision", "no-such-card",
		"bad-target-count", "bad-target-count", "no-such-object"} {
		if !strings.Contains(out, "ERR "+itoa(i+1)+" "+want) {
			t.Errorf("missing ERR %d %s in\n%s", i+1, want, out)
		}
	}
	mustContain(t, out, "ERR 8 illegal-target")
}

func itoa(n int) string { return string(rune('0' + n)) }

func TestCombatRiposteAndDamage(t *testing.T) {
	g := newGame(t, "FIELD A TST-009", "FIELD B TST-002")
	out := play(t, g, "A PASS", "B PASS", "A ATTACK #1", "A PASS", "B PASS", "B BLOCK #2:#1", "A PASS", "B PASS")
	mustContain(t, out, "PHASE clash-riposte", "DAMAGE #1 #2 2", "DESTROY #2 TST-002")
	out = string(g.Output())
	if strings.Contains(out, "DAMAGE #2 #1") {
		t.Errorf("the dead blocker must not deal damage:\n%s", out)
	}
	out = play(t, g, "A PASS", "B PASS")
	mustContain(t, out, "PHASE clash-damage")
}

func TestLegalAttackersAndBlockers(t *testing.T) {
	g := newGame(t, "FIELD A TST-002", "FIELD B TST-002")
	out := play(t, g, "A PASS", "B PASS", "LEGAL", "A ATTACK #1", "A PASS", "B PASS", "LEGAL")
	mustContain(t, out, "LEGAL BEGIN A attackers\nCANATTACK #1\nLEGAL END",
		"LEGAL BEGIN B blockers\nCANBLOCK #2 #1\nLEGAL END")
}

func TestEmptyVaultLoses(t *testing.T) {
	g := newGame(t, "DECK A TST-002")
	// The turn-1 first player skips the draw; pass to B, whose draw finds an empty vault.
	var lines []string
	for i := 0; i < 3; i++ {
		lines = append(lines, "A PASS", "B PASS")
	}
	lines = append(lines, "A ATTACK", "A PASS", "B PASS", "A PASS", "B PASS", "A PASS", "B PASS")
	out := play(t, g, lines...)
	mustContain(t, out, "DRAW-EMPTY B", "LOSE B vault", "RESULT A vault")
	if !g.Over() {
		t.Error("match should be over")
	}
}

func TestConcedeAndGameOver(t *testing.T) {
	g := newGame(t)
	out := play(t, g, "A CONCEDE", "A PASS", "DUMP")
	mustContain(t, out, "LOSE A concede", "RESULT B concede", "ERR 2 game-over",
		"decision - over", "result B concede")
}

func TestTurnLimitDraw(t *testing.T) {
	g := newGame(t, "TURNLIMIT 1", "DECK A TST-002*3", "DECK B TST-002*3")
	lines := []string{"A PASS", "B PASS", "A ATTACK", "A PASS", "B PASS", "A PASS", "B PASS", "A PASS", "B PASS"}
	out := play(t, g, append(lines, "DUMP")...)
	mustContain(t, out, "RESULT draw turn-limit", "turn 2 active B phase dusk-cleanup decision - over")
}

func TestTraceStatePrintsAfterAcceptedActions(t *testing.T) {
	g := newGame(t, "TRACE state")
	out := play(t, g, "A PASS", "A PASS", "X")
	if strings.Count(out, "STATE BEGIN") != 1 {
		t.Errorf("want exactly one trace block:\n%s", out)
	}
}

func TestCardDirective(t *testing.T) {
	g := newGame(t)
	out := play(t, g, "CARD TST-001", "CARD NOPE-1")
	mustContain(t, out, "CARD BEGIN TST-001\nname Bolt\ntype rite\ncost 1\ntags -\nkeywords swift\n"+
		"ability 1 resolve (targets (any)) (damage 2 (t 1))\nCARD END",
		"CARD BEGIN NOPE-1\nunknown\nCARD END")
}

func TestDeterministicShuffle(t *testing.T) {
	db, _ := cards.Parse([]byte(testDB))
	f, _ := match.ParseFile("CARDS x\nSEED 7\nOPENING 0\nDECK A TST-001 TST-002 TST-003 TST-004 TST-005 TST-006 TST-007 TST-008\nSTART\nVAULT\n")
	g, err := engine.New(db, f.Setup)
	if err != nil {
		t.Fatal(err)
	}
	cmd, _ := match.ParseCommand("VAULT")
	g.Exec(cmd, 1)
	mustContain(t, string(g.Output()), "vault A 1 #6 TST-006", "vault A 2 #8 TST-008", "vault A 3 #5 TST-005")
}
