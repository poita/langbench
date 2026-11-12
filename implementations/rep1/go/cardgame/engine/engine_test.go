package engine_test

import (
	"bytes"
	"errors"
	"strings"
	"testing"

	"github.com/spiremark/cardgame/cards"
	"github.com/spiremark/cardgame/engine"
)

func newGame(t *testing.T, mutate func(*engine.Config)) (*engine.Game, *bytes.Buffer) {
	t.Helper()
	db, err := cards.Load("../testdata/mini.spire")
	if err != nil {
		t.Fatal(err)
	}
	cfg := engine.DefaultConfig()
	cfg.Spire, cfg.Opening, cfg.Shuffle = 10, 0, false
	cfg.Deck[engine.A] = []engine.CardCount{{ID: "CIN-001", Count: 3}}
	cfg.Deck[engine.B] = []engine.CardCount{{ID: "CIN-001", Count: 3}}
	if mutate != nil {
		mutate(&cfg)
	}
	var out bytes.Buffer
	g, err := engine.New(cfg, db, &out)
	if err != nil {
		t.Fatal(err)
	}
	return g, &out
}

func pass(p engine.Player) engine.Action { return engine.Action{Kind: engine.ActPass, Player: p} }

func kindOf(err error) string {
	var ae *engine.ActionError
	if errors.As(err, &ae) {
		return ae.Kind
	}
	return "<" + errOrNil(err) + ">"
}

func errOrNil(err error) string {
	if err == nil {
		return "nil"
	}
	return err.Error()
}

func TestSetupReachesFirstDecision(t *testing.T) {
	g, out := newGame(t, nil)
	if p, k := g.Decision(); p != engine.A || k != engine.DecPriority {
		t.Fatalf("decision %v %v", p, k)
	}
	if g.Phase() != "main1" || g.Turn() != 1 {
		t.Fatalf("phase %s turn %d", g.Phase(), g.Turn())
	}
	want := "1 GAME-START A\n2 TURN 1 A\n3 PHASE dawn\n4 EMBER A 1 1\n5 EMBER B 0 0\n6 PHASE draw\n7 PHASE main1\n"
	if out.String() != want {
		t.Errorf("events:\n%s", out.String())
	}
}

func TestUnknownCard(t *testing.T) {
	db, _ := cards.Load("../testdata/mini.spire")
	cfg := engine.DefaultConfig()
	cfg.Hand[engine.A] = []engine.CardCount{{ID: "ZZZ-999", Count: 1}}
	if _, err := engine.New(cfg, db, &bytes.Buffer{}); !errors.Is(err, engine.ErrUnknownCard) {
		t.Fatalf("got %v", err)
	}
}

func TestRejectedActionsChangeNothing(t *testing.T) {
	g, out := newGame(t, func(c *engine.Config) {
		c.Hand[engine.A] = []engine.CardCount{{ID: "CIN-003", Count: 1}, {ID: "CIN-016", Count: 1}}
	})
	before := out.String()
	cases := []struct {
		name string
		act  engine.Action
		want string
	}{
		{"wrong player", pass(engine.B), "not-your-turn"},
		{"attack at priority", engine.Action{Kind: engine.ActAttack, Player: engine.A}, "wrong-decision"},
		{"block at priority", engine.Action{Kind: engine.ActBlock, Player: engine.A}, "wrong-decision"},
		{"no such card", engine.Action{Kind: engine.ActPlay, Player: engine.A, Pos: 9}, "no-such-card"},
		{"target count", engine.Action{Kind: engine.ActPlay, Player: engine.A, Pos: 1}, "bad-target-count"},
		{"illegal target", engine.Action{Kind: engine.ActPlay, Player: engine.A, Pos: 1,
			Targets: []engine.TargetRef{{Kind: engine.RefObject, ID: 99}}}, "illegal-target"},
		{"cannot afford", engine.Action{Kind: engine.ActPlay, Player: engine.A, Pos: 2}, "cannot-afford"},
		{"no such object", engine.Action{Kind: engine.ActAct, Player: engine.A, Object: 1, Index: 1}, "no-such-object"},
	}
	for _, tc := range cases {
		if got := kindOf(g.Do(tc.act)); got != tc.want {
			t.Errorf("%s: got %s want %s", tc.name, got, tc.want)
		}
	}
	if out.String() != before {
		t.Errorf("rejected actions emitted events:\n%s", out.String()[len(before):])
	}
}

func TestPlayRiteAndResolve(t *testing.T) {
	g, out := newGame(t, func(c *engine.Config) {
		c.Hand[engine.A] = []engine.CardCount{{ID: "CIN-003", Count: 1}}
	})
	start := out.Len()
	play := engine.Action{Kind: engine.ActPlay, Player: engine.A, Pos: 1,
		Targets: []engine.TargetRef{{Kind: engine.RefPlayer, Player: engine.B}}}
	for _, a := range []engine.Action{play, pass(engine.A), pass(engine.B)} {
		if err := g.Do(a); err != nil {
			t.Fatal(err)
		}
	}
	want := "8 PLAY A ~1 #4 CIN-003 B\n9 PAY A ember 1\n10 PASS A\n11 PASS B\n12 RESOLVE ~1\n" +
		"13 DAMAGE #4 B 2\n14 SPIRE B -2 8\n15 SPENT #4 CIN-003\n"
	if got := out.String()[start:]; got != want {
		t.Errorf("events:\n%s\nwant:\n%s", got, want)
	}
}

func TestConcede(t *testing.T) {
	g, out := newGame(t, nil)
	if err := g.Do(engine.Action{Kind: engine.ActConcede, Player: engine.A}); err != nil {
		t.Fatal(err)
	}
	r := g.Result()
	if !r.Over || r.Winner != "B" || r.Reason != "concede" {
		t.Fatalf("result %+v", r)
	}
	if !strings.HasSuffix(out.String(), "8 LOSE A concede\n9 RESULT B concede\n") {
		t.Errorf("events:\n%s", out.String())
	}
	if got := kindOf(g.Do(pass(engine.A))); got != "game-over" {
		t.Errorf("after the end: %s", got)
	}
	var legal bytes.Buffer
	g.Legal(&legal)
	if legal.String() != "LEGAL BEGIN - over\nLEGAL END\n" {
		t.Errorf("legal after end: %q", legal.String())
	}
	g.Finish() // must not add a second RESULT line
	if strings.Count(out.String(), "RESULT") != 1 {
		t.Error("exactly one RESULT line expected")
	}
}

func TestTurnLimitDraw(t *testing.T) {
	g, out := newGame(t, func(c *engine.Config) { c.TurnLimit = 1 })
	for i := 0; i < 40 && !g.Result().Over; i++ {
		p, k := g.Decision()
		var err error
		switch k {
		case engine.DecAttackers:
			err = g.Do(engine.Action{Kind: engine.ActAttack, Player: p})
		default:
			err = g.Do(pass(p))
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	r := g.Result()
	if !r.Over || r.Winner != "draw" || r.Reason != "turn-limit" {
		t.Fatalf("result %+v\n%s", r, out.String())
	}
	var dump bytes.Buffer
	g.Dump(&dump)
	if !strings.Contains(dump.String(), "turn 2 active B phase dusk-cleanup decision - over") {
		t.Errorf("dump:\n%s", dump.String())
	}
}

func TestVaultLossAtSetup(t *testing.T) {
	_, out := newGame(t, func(c *engine.Config) {
		c.Opening = 5
		c.Deck[engine.A] = []engine.CardCount{{ID: "CIN-001", Count: 2}}
		c.Deck[engine.B] = []engine.CardCount{{ID: "CIN-001", Count: 9}}
	})
	if !strings.Contains(out.String(), "DRAW-EMPTY A") || !strings.Contains(out.String(), "RESULT B vault") {
		t.Errorf("events:\n%s", out.String())
	}
	if strings.Contains(out.String(), "TURN 1") {
		t.Error("the match ended before turn 1 began")
	}
}

func TestDeterministicShuffle(t *testing.T) {
	mutate := func(c *engine.Config) { c.Shuffle, c.Seed = true, 7 }
	_, a := newGame(t, mutate)
	_, b := newGame(t, mutate)
	if a.String() != b.String() || !strings.Contains(a.String(), "SHUFFLE A") {
		t.Error("same seed must give identical output")
	}
}

func TestLegalAttackersAndBlockers(t *testing.T) {
	g, _ := newGame(t, func(c *engine.Config) {
		c.Field[engine.A] = []engine.CardCount{{ID: "TOK-001", Count: 1}}
		c.Field[engine.B] = []engine.CardCount{{ID: "TOK-005", Count: 1}}
	})
	for _, a := range []engine.Action{pass(engine.A), pass(engine.B)} {
		if err := g.Do(a); err != nil {
			t.Fatal(err)
		}
	}
	if got := g.LegalActions(); len(got) != 1 || got[0] != "CANATTACK #4" {
		t.Fatalf("attackers: %v", got)
	}
	if got := kindOf(g.Do(engine.Action{Kind: engine.ActAttack, Player: engine.A, Attackers: []uint64{4, 4}})); got != "duplicate-attacker" {
		t.Errorf("got %s", got)
	}
	if got := kindOf(g.Do(engine.Action{Kind: engine.ActAttack, Player: engine.A, Attackers: []uint64{8}})); got != "illegal-attacker" {
		t.Errorf("got %s", got)
	}
	if err := g.Do(engine.Action{Kind: engine.ActAttack, Player: engine.A, Attackers: []uint64{4}}); err != nil {
		t.Fatal(err)
	}
	g.Do(pass(engine.A))
	g.Do(pass(engine.B))
	if p, k := g.Decision(); p != engine.B || k != engine.DecBlockers {
		t.Fatalf("decision %v %v", p, k)
	}
	if got := g.LegalActions(); len(got) != 1 || got[0] != "CANBLOCK #8 #4" {
		t.Fatalf("blockers: %v", got)
	}
	if got := kindOf(g.Do(engine.Action{Kind: engine.ActBlock, Player: engine.B,
		Blocks: []engine.BlockPair{{Blocker: 8, Attacker: 4}, {Blocker: 8, Attacker: 4}}})); got != "duplicate-blocker" {
		t.Errorf("got %s", got)
	}
	if err := g.Do(engine.Action{Kind: engine.ActBlock, Player: engine.B,
		Blocks: []engine.BlockPair{{Blocker: 8, Attacker: 4}}}); err != nil {
		t.Fatal(err)
	}
	var dump bytes.Buffer
	g.Dump(&dump)
	for _, want := range []string{"field A #4 TOK-001 1/1 w0 c0 exhausted attacking,blocked kw -", "field B #8 TOK-005 1/1 w0 c0 ready blocking kw venom"} {
		if !strings.Contains(dump.String(), want) {
			t.Errorf("dump lacks %q:\n%s", want, dump.String())
		}
	}
}

func TestNegateAndChainedTargets(t *testing.T) {
	g, out := newGame(t, func(c *engine.Config) {
		c.Cap = [2]int{3, 3}
		c.Hand[engine.A] = []engine.CardCount{{ID: "CIN-003", Count: 1}}
		c.Hand[engine.B] = []engine.CardCount{{ID: "TID-004", Count: 1}}
	})
	acts := []engine.Action{
		{Kind: engine.ActPlay, Player: engine.A, Pos: 1, Targets: []engine.TargetRef{{Kind: engine.RefPlayer, Player: engine.B}}},
		pass(engine.A),
		{Kind: engine.ActPlay, Player: engine.B, Pos: 1, Targets: []engine.TargetRef{{Kind: engine.RefEntry, ID: 1}}},
		pass(engine.B),
		pass(engine.A),
	}
	for _, a := range acts {
		if err := g.Do(a); err != nil {
			t.Fatalf("%+v: %v", a, err)
		}
	}
	for _, want := range []string{"RESOLVE ~2", "NEGATE ~1", "SPENT #4 CIN-003", "SPENT #8 TID-004"} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("missing %q:\n%s", want, out.String())
		}
	}
	if strings.Contains(out.String(), "DAMAGE") {
		t.Error("negated bolt must not deal damage")
	}
}
