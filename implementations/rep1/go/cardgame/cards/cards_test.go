package cards

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const dataDir = "../../problems/cardgame/data"

func loadData(t *testing.T, name string) *DB {
	t.Helper()
	db, err := Load(filepath.Join(dataDir, name))
	if err != nil {
		t.Skipf("data file unavailable: %v", err)
	}
	return db
}

func TestShippedDatabases(t *testing.T) {
	if _, err := os.Stat(dataDir); err != nil {
		t.Skip("problem data not present")
	}
	for name, n := range map[string]int{"cards.spire": 200, "extra.spire": 33, "lexer.spire": 2, "empty.spire": 0} {
		db, err := Load(filepath.Join(dataDir, name))
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if len(db.Cards()) != n {
			t.Errorf("%s: %d cards, want %d", name, len(db.Cards()), n)
		}
	}
}

func TestBadDatabases(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join(dataDir, "bad", "*.spire"))
	if len(files) == 0 {
		t.Skip("no bad databases present")
	}
	for _, f := range files {
		if _, err := Load(f); err != ErrBadDatabase {
			t.Errorf("%s: got %v, want ErrBadDatabase", f, err)
		}
	}
	if _, err := Load("/nonexistent/db.spire"); err != ErrBadDatabase {
		t.Errorf("missing file: %v", err)
	}
}

func TestParseInline(t *testing.T) {
	good := `(card AAA-001 (name "x") (type rite) (cost 1) (keywords swift)
	  (resolve (targets (any)) (if (myturn) ((nothing)) ()) (damage 1 (t 1))))`
	db, err := Parse([]byte(good))
	if err != nil {
		t.Fatal(err)
	}
	c := db.Card("AAA-001")
	if c == nil || !c.HasKeyword(Swift) || len(c.Abilities) != 1 {
		t.Fatalf("unexpected card %+v", c)
	}
	for _, src := range []string{
		`(card AAA-001 (name "x") (type unit) (cost 1))`,
		`(card AAA-001 (name "x") (type relic) (cost 1) (keywords swift))`,
		`(card AAA-001 (name "x") (type rite) (cost 1) (resolve (draw 1 self)))`,
	} {
		if _, err := Parse([]byte(src)); err == nil {
			t.Errorf("accepted invalid database %q", src)
		}
	}
}

func TestDescribe(t *testing.T) {
	db := loadData(t, "cards.spire")
	got := strings.Join(db.Card("DSK-020").Describe(), "\n")
	want := `name Grim Harvester
type unit
cost 3
body 2/2
tags dusk,undead
keywords -
ability 1 on spire-loss - (counters 1 self)
ability 2 act (cost (exhaust) (spire 2)) (targets (unit)) (damage 2 (t 1))`
	if got != want {
		t.Errorf("got:\n%s\nwant:\n%s", got, want)
	}
	got = strings.Join(db.Card("LOM-039").Describe(), "\n")
	if !strings.Contains(got, "ability 2 aura (grant (plating 1) (units yours))") {
		t.Errorf("aura rendering wrong:\n%s", got)
	}
}

func TestAuraDeps(t *testing.T) {
	db := loadData(t, "cards.spire")
	leaf := db.Card("LOM-006").Abilities[0].Leaves[0] // (when (myturn) ...)
	if leaf.Deps&DepTurn == 0 || len(leaf.Conds) != 1 {
		t.Errorf("LOM-006 leaf: %+v", leaf)
	}
	if db.Card("LOM-005").Abilities[0].Leaves[0].Deps != 0 {
		t.Errorf("LOM-005 should have no dynamic dependencies")
	}
}
