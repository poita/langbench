package match

import (
	"reflect"
	"testing"
)

func TestParseSetupDefaults(t *testing.T) {
	f, err := ParseFile("# c\nCARDS data/cards.spire\r\nSEED 007\n\n  DECK A CIN-001*3 TOK-001\nSTART\nA PASS\n")
	if err != nil {
		t.Fatal(err)
	}
	s := f.Setup
	if s.Seed != 7 || s.Spire != 25 || s.Opening != 5 || !s.Shuffle || s.TurnLimit != 200 {
		t.Errorf("setup %+v", s)
	}
	want := []Entry{{"CIN-001", 3}, {"TOK-001", 1}}
	if !reflect.DeepEqual(s.Zones[0][ZoneDeck], want) {
		t.Errorf("deck %v", s.Zones[0][ZoneDeck])
	}
	if len(f.Script) != 1 || f.Script[0].No != 7 {
		t.Errorf("script %+v", f.Script)
	}
}

func TestBadSetup(t *testing.T) {
	bad := []string{
		"SEED 1\nSTART\n",
		"CARDS x\nSTART\n",
		"CARDS x\nSEED 1\n",
		"CARDS x\nSEED 1\nSEED 2\nSTART\n",
		"CARDS x\nSEED -1\nSTART\n",
		"CARDS x\nSEED 18446744073709551616\nSTART\n",
		"CARDS x\nSEED 1\nSPIRE 0\nSTART\n",
		"CARDS x\nSEED 1\nHANDMAX 101\nSTART\n",
		"CARDS x\nSEED 1\nDECK A\nSTART\n",
		"CARDS x\nSEED 1\nDECK A X*0\nSTART\n",
		"CARDS x\nSEED 1\nDECK A X*1001\nSTART\n",
		"CARDS x\nSEED 1\nDECK C X\nSTART\n",
		"CARDS x\nSEED 1\nCAP A 1\nCAP A 2\nSTART\n",
		"CARDS x\nSEED 1\nFOO\nSTART\n",
		"CARDS x\nSEED 1\nSTART now\n",
	}
	for _, b := range bad {
		if _, err := ParseFile(b); err != ErrBadSetup {
			t.Errorf("%q: got %v", b, err)
		}
	}
	if _, err := ParseFile("CARDS x\nSEED 1\nCAP A 1\nCAP B 2\nSTART"); err != nil {
		t.Errorf("CAP A and CAP B are separate lines: %v", err)
	}
}

func TestParseCommand(t *testing.T) {
	c, err := ParseCommand("A PLAY 01 A #007 ~3")
	if err != nil || c.Kind != CmdPlay || c.Pos != 1 || len(c.Targets) != 3 ||
		c.Targets[1] != (Token{TokObject, 7}) || c.Targets[2] != (Token{TokChain, 3}) {
		t.Errorf("%+v %v", c, err)
	}
	c, err = ParseCommand("B BLOCK #4:#2 #5:#2")
	if err != nil || len(c.Pairs) != 2 || c.Pairs[1] != (Pair{5, 2}) {
		t.Errorf("%+v %v", c, err)
	}
	for _, bad := range []string{
		"X PASS", "A BLOCK x", "A PLAY", "A PLAY -1", "A PLAY 99999999999999999999",
		"DUMP x", "CARD", "CARD a b", "A ATTACK 5", "A ACT #1", "A PASS now", "a PASS", "A",
	} {
		if _, err := ParseCommand(bad); err != ErrBadSyntax {
			t.Errorf("%q accepted", bad)
		}
	}
}
