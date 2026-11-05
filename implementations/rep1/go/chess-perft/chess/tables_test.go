package chess

import "testing"

func sq(t *testing.T, s string) Square {
	t.Helper()
	v, err := ParseSquare(s)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func TestLeaperTables(t *testing.T) {
	cases := []struct {
		name string
		got  Bitboard
		n    int
	}{
		{"knight a1", KnightAttacks(sq(t, "a1")), 2},
		{"knight d4", KnightAttacks(sq(t, "d4")), 8},
		{"king a1", KingAttacks(sq(t, "a1")), 3},
		{"king e4", KingAttacks(sq(t, "e4")), 8},
		{"white pawn a2", PawnAttacks(White, sq(t, "a2")), 1},
		{"black pawn e7", PawnAttacks(Black, sq(t, "e7")), 2},
		{"white pawn e8", PawnAttacks(White, sq(t, "e8")), 0},
	}
	for _, c := range cases {
		if c.got.Count() != c.n {
			t.Errorf("%s: %d squares, want %d\n%v", c.name, c.got.Count(), c.n, c.got)
		}
	}
	if !PawnAttacks(White, sq(t, "e4")).Has(sq(t, "d5")) || !PawnAttacks(Black, sq(t, "e4")).Has(sq(t, "f3")) {
		t.Error("pawn attack direction wrong")
	}
}

func TestSliderAttacks(t *testing.T) {
	d4 := sq(t, "d4")
	if got := RookAttacks(d4, 0).Count(); got != 14 {
		t.Errorf("empty-board rook: %d, want 14", got)
	}
	if got := BishopAttacks(d4, 0).Count(); got != 13 {
		t.Errorf("empty-board bishop: %d, want 13", got)
	}
	if got := QueenAttacks(d4, 0).Count(); got != 27 {
		t.Errorf("empty-board queen: %d, want 27", got)
	}
	// Blockers on d6 (north), b4 (west), f6 (north-east), c3 (south-west).
	occ := sq(t, "d6").Bitboard() | sq(t, "b4").Bitboard() | sq(t, "f6").Bitboard() | sq(t, "c3").Bitboard()
	r := RookAttacks(d4, occ)
	for _, want := range []string{"d5", "d6", "c4", "b4", "d1", "h4"} {
		if !r.Has(sq(t, want)) {
			t.Errorf("rook should attack %s", want)
		}
	}
	for _, not := range []string{"d7", "a4"} {
		if r.Has(sq(t, not)) {
			t.Errorf("rook should not attack %s", not)
		}
	}
	b := BishopAttacks(d4, occ)
	for _, want := range []string{"e5", "f6", "c3", "a7", "g1"} {
		if !b.Has(sq(t, want)) {
			t.Errorf("bishop should attack %s", want)
		}
	}
	if b.Has(sq(t, "g7")) || b.Has(sq(t, "b2")) {
		t.Error("bishop attacks past a blocker")
	}
}

func TestBetweenAndLine(t *testing.T) {
	if got := Between(sq(t, "a1"), sq(t, "a8")); got.Count() != 6 {
		t.Errorf("between a1,a8: %d squares", got.Count())
	}
	if got := Between(sq(t, "a1"), sq(t, "h8")); got.Count() != 6 || got.Has(sq(t, "a1")) || got.Has(sq(t, "h8")) {
		t.Errorf("between a1,h8 wrong:\n%v", got)
	}
	if Between(sq(t, "a1"), sq(t, "b3")) != 0 || Line(sq(t, "a1"), sq(t, "b3")) != 0 {
		t.Error("non-aligned squares must give empty sets")
	}
	if Between(sq(t, "e4"), sq(t, "e5")) != 0 {
		t.Error("adjacent squares have nothing between")
	}
	l := Line(sq(t, "c3"), sq(t, "e5"))
	if l.Count() != 8 || !l.Has(sq(t, "a1")) || !l.Has(sq(t, "h8")) {
		t.Errorf("line c3,e5 wrong:\n%v", l)
	}
	if Line(sq(t, "c3"), sq(t, "e5")) != Line(sq(t, "e5"), sq(t, "c3")) {
		t.Error("line must be symmetric")
	}
}
