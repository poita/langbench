package cards

import (
	"errors"
	"strings"
	"testing"
)

func mustParse(t *testing.T, src string) *Database {
	t.Helper()
	db, err := Parse(src)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	return db
}

func TestLoadFixture(t *testing.T) {
	db, err := Load("../testdata/mini.spire")
	if err != nil {
		t.Fatal(err)
	}
	if db.Len() < 20 {
		t.Fatalf("only %d cards", db.Len())
	}
	c, ok := db.Get("CIN-003")
	if !ok || c.Type != Rite || !c.HasPrinted(Swift) || c.Cost != 1 {
		t.Fatalf("bad CIN-003: %+v", c)
	}
}

func TestLoadMissingFile(t *testing.T) {
	_, err := Load("does/not/exist.spire")
	if !errors.Is(err, ErrBadDatabase) {
		t.Fatalf("want ErrBadDatabase, got %v", err)
	}
}

func TestBlock(t *testing.T) {
	db, err := Load("../testdata/mini.spire")
	if err != nil {
		t.Fatal(err)
	}
	cases := map[string]string{
		"CIN-003": `CARD BEGIN CIN-003
name Searing Bolt
type rite
cost 1
tags cinder
keywords swift
ability 1 resolve (targets (any)) (damage 2 (t 1))
CARD END
`,
		"DSK-020": `CARD BEGIN DSK-020
name Grim Harvester
type unit
cost 3
body 2/2
tags dusk,undead
keywords -
ability 1 on spire-loss - (counters 1 self)
ability 2 act (cost (exhaust) (spire 2)) (targets (unit)) (damage 2 (t 1))
CARD END
`,
		"LOM-039": `CARD BEGIN LOM-039
name Heartwood Shrine
type relic
cost 5
tags loam
keywords -
ability 1 aura (modify 1 1 (units yours))
ability 2 aura (grant (plating 1) (units yours))
CARD END
`,
	}
	for id, want := range cases {
		c, _ := db.Get(id)
		if got := c.Block(); got != want {
			t.Errorf("%s:\n%s\nwant:\n%s", id, got, want)
		}
	}
	if got := UnknownBlock("ZZZ-999"); got != "CARD BEGIN ZZZ-999\nunknown\nCARD END\n" {
		t.Errorf("unknown block: %q", got)
	}
}

func TestAbilityNumbering(t *testing.T) {
	db := mustParse(t, `(card AAA-001 (name "x") (type unit) (cost 1) (body 1 1)
	  (aura (modify 1 1 self))
	  (act (cost (once)) (draw 1 you))
	  (on arrive (draw 1 you))
	  (on dies (draw 2 you)))`)
	c, _ := db.Get("AAA-001")
	kinds := []AbilityKind{AbOn, AbOn, AbAct, AbAura}
	for i, k := range kinds {
		if c.Ability(i+1).Kind != k || c.Ability(i+1).Index != i+1 {
			t.Errorf("ability %d: %+v", i+1, c.Ability(i+1))
		}
	}
	if c.Ability(0) != nil || c.Ability(5) != nil {
		t.Error("out-of-range ability should be nil")
	}
}

func TestCanonicalPrintingNormalisesWhitespace(t *testing.T) {
	db := mustParse(t, "(card AAA-001 (name \"x\") (type rite) (cost 0)\n (resolve   (if (myturn)\n ((draw 1 you))\n  ((draw   02 foe)))))")
	c, _ := db.Get("AAA-001")
	want := "ability 1 resolve - (if (myturn) ((draw 1 you)) ((draw 2 foe)))"
	if !strings.Contains(c.Block(), want) {
		t.Errorf("block:\n%s", c.Block())
	}
}

func TestEmptyDatabase(t *testing.T) {
	db := mustParse(t, "; nothing\n")
	if db.Len() != 0 {
		t.Fatal("expected empty database")
	}
}

func TestInvalidDatabases(t *testing.T) {
	const unit = `(card AAA-001 (name "One") (type unit) (cost 0) (body 1 1)`
	const rite = `(card AAA-001 (name "One") (type rite) (cost 1)`
	bad := map[string]string{
		"unbalanced":           unit,
		"extra paren":          unit + "))",
		"unterminated string":  `(card AAA-001 (name "One) (type unit) (cost 0) (body 1 1))`,
		"stray atom":           "card\n" + unit + ")",
		"not a card":           `(deck AAA-001)`,
		"lower-case id":        `(card aaa-001 (name "One") (type unit) (cost 0) (body 1 1))`,
		"long id":              `(card AAA-0012 (name "One") (type unit) (cost 0) (body 1 1))`,
		"duplicate id":         unit + ")" + unit + ")",
		"no name":              `(card AAA-001 (type unit) (cost 0) (body 1 1))`,
		"two names":            `(card AAA-001 (name "a") (name "b") (type unit) (cost 0) (body 1 1))`,
		"bad type":             `(card AAA-001 (name "a") (type thing) (cost 0) (body 1 1))`,
		"negative cost":        `(card AAA-001 (name "a") (type unit) (cost -1) (body 1 1))`,
		"huge cost":            `(card AAA-001 (name "a") (type unit) (cost 99999999999999999999) (body 1 1))`,
		"body on rite":         rite + ` (body 1 1) (resolve (nothing)))`,
		"unit without body":    `(card AAA-001 (name "a") (type unit) (cost 0))`,
		"negative body":        `(card AAA-001 (name "a") (type unit) (cost 0) (body 1 -1))`,
		"swift on unit":        unit + ` (keywords swift))`,
		"vanguard on relic":    `(card AAA-001 (name "a") (type relic) (cost 0) (keywords vanguard) (aura (modify 1 1 self)))`,
		"unit keyword on rite": rite + ` (keywords pierce) (resolve (nothing)))`,
		"plating without val":  unit + ` (keywords plating))`,
		"act without cost":     unit + ` (act (draw 1 you)))`,
		"act two costs":        unit + ` (act (cost (once)) (cost (once)) (draw 1 you)))`,
		"act no effect":        unit + ` (act (cost (once))))`,
		"targets after effect": rite + ` (resolve (draw 1 you) (targets (unit))))`,
		"two targets clauses":  rite + ` (resolve (targets (unit)) (targets (unit)) (destroy (t 1))))`,
		"cost in resolve":      rite + ` (resolve (cost (ember 1)) (draw 1 you)))`,
		"rite no resolve":      rite + `)`,
		"resolve on unit":      unit + ` (resolve (draw 1 you)))`,
		"empty resolve":        rite + ` (resolve))`,
		"empty aura":           `(card AAA-001 (name "a") (type relic) (cost 0) (aura))`,
		"summon unknown":       rite + ` (resolve (summon BBB-002 1 you)))`,
		"conjure unknown":      rite + ` (resolve (conjure BBB-002 1 you)))`,
		"summon rite":          rite + ` (resolve (summon AAA-001 1 you)))`,
		"unknown clause":       unit + ` (flavour "x"))`,
		"unknown effect":       rite + ` (resolve (explode 2 foe)))`,
		"bad arity":            rite + ` (resolve (damage 2)))`,
		"bad comparator":       rite + ` (resolve (damage 2 (units theirs (cost gte 2)))))`,
		"bad filter":           rite + ` (resolve (destroy (units all (colour red)))))`,
		"bad scope":            rite + ` (resolve (destroy (units mine))))`,
		"unknown event":        unit + ` (on sunrise (draw 1 you)))`,
		"unknown keyword":      unit + ` (keywords flying))`,
		"symbol cost":          `(card AAA-001 (name "a") (type unit) (cost two) (body 1 1))`,
		"bad static":           `(card AAA-001 (name "a") (type relic) (cost 0) (aura (destroy (units theirs))))`,
		"bad delay timing":     rite + ` (resolve (delay sunset (draw 1 you))))`,
		"bad cost item":        unit + ` (act (cost (tap)) (draw 1 you)))`,
		"name as symbol":       `(card AAA-001 (name One) (type unit) (cost 0) (body 1 1))`,
		"text twice":           unit + ` (text "a") (text "b"))`,
		"dig amount":           rite + ` (resolve (dig (hand you) ((type unit)) you)))`,
		"bad player sel":       rite + ` (resolve (draw 1 everyone)))`,
		"bad target spec":      rite + ` (resolve (targets (planet)) (draw 1 you)))`,
		"negate non-target":    rite + ` (resolve (negate self)))`,
		"if with bare effect":  rite + ` (resolve (if (myturn) (draw 1 you))))`,
		"newline in string":    "(card AAA-001 (name \"a\nb\") (type unit) (cost 0) (body 1 1))",
	}
	for name, src := range bad {
		if !strings.HasSuffix(strings.TrimSpace(src), ")") && name != "unbalanced" {
			src += ")"
		}
		if _, err := Parse(src); err == nil {
			t.Errorf("%s: expected an error", name)
		} else if !errors.Is(err, ErrBadDatabase) {
			t.Errorf("%s: error does not wrap ErrBadDatabase: %v", name, err)
		}
	}
}

func TestComparators(t *testing.T) {
	cases := []struct {
		c    Cmp
		l, r int
		want bool
	}{
		{Le, 1, 1, true}, {Lt, 1, 1, false}, {Eq, 2, 2, true},
		{Ge, 1, 2, false}, {Gt, 3, 2, true}, {Ne, 3, 3, false},
	}
	for _, tc := range cases {
		if got := tc.c.Test(tc.l, tc.r); got != tc.want {
			t.Errorf("%v %d %d = %v", tc.c, tc.l, tc.r, got)
		}
	}
}

func TestKeywordRendering(t *testing.T) {
	if got := (KW{K: Plating, N: 3}).String(); got != "plating:3" {
		t.Error(got)
	}
	if got := (KW{K: Riposte}).String(); got != "riposte" {
		t.Error(got)
	}
	if _, ok := KeywordByName("flying"); ok {
		t.Error("flying is not a keyword")
	}
}
