package chess

import "testing"

func TestAttackTables(t *testing.T) {
	e4, _ := ParseSquare("e4")
	if KnightAttacks(e4).Count() != 8 || KingAttacks(e4).Count() != 8 {
		t.Error("central knight/king should attack 8 squares")
	}
	if KnightAttacks(A1).Count() != 2 || KingAttacks(A1).Count() != 3 {
		t.Error("corner knight/king attack counts")
	}
	if PawnAttacks(White, e4).Count() != 2 || PawnAttacks(White, e4).Lsb() != NewSquare(3, 4) {
		t.Error("white pawn attacks")
	}
	if PawnAttacks(Black, NewSquare(0, 6)) != NewSquare(1, 5).Bit() {
		t.Error("black edge pawn attacks")
	}
	if RookAttacks(e4, 0).Count() != 14 || BishopAttacks(e4, 0).Count() != 13 {
		t.Error("empty-board slider attack counts")
	}
}

func TestSliderBlockers(t *testing.T) {
	// Rook on a1 with blockers on a4 and d1: sees a2 a3 a4 b1 c1 d1.
	occ := NewSquare(0, 3).Bit() | NewSquare(3, 0).Bit() | NewSquare(7, 7).Bit()
	want := NewSquare(0, 1).Bit() | NewSquare(0, 2).Bit() | NewSquare(0, 3).Bit() |
		NewSquare(1, 0).Bit() | NewSquare(2, 0).Bit() | NewSquare(3, 0).Bit()
	if got := RookAttacks(A1, occ); got != want {
		t.Errorf("rook attacks:\n%v want\n%v", got, want)
	}
	// Bishop on h8 blocked at e5 on the long diagonal.
	if got := BishopAttacks(63, NewSquare(4, 4).Bit()); got.Count() != 3 {
		t.Errorf("bishop attacks:\n%v", got)
	}
	// Downward-pointing rays stop at the highest blocker below.
	if got := RookAttacks(H8, NewSquare(7, 3).Bit()|NewSquare(7, 5).Bit()); !got.Has(NewSquare(7, 5)) || got.Has(NewSquare(7, 4)) {
		t.Errorf("negative ray blocking:\n%v", got)
	}
}

func TestBetweenAndLine(t *testing.T) {
	e1, e8, d2 := NewSquare(4, 0), NewSquare(4, 7), NewSquare(3, 1)
	if between[e1][e8].Count() != 6 || between[e8][e1] != between[e1][e8] {
		t.Error("between on a file")
	}
	if between[e1][d2] != 0 || between[A1][NewSquare(1, 2)] != 0 {
		t.Error("adjacent or unaligned squares have nothing between")
	}
	if line[e1][NewSquare(4, 3)].Count() != 8 || line[A1][H8].Count() != 8 {
		t.Error("line through two aligned squares")
	}
	// A diagonal and its opposite must pair up correctly (regression: the
	// opposite of NE is SW, not SE).
	e7 := NewSquare(4, 6)
	if line[e7][NewSquare(5, 5)].Has(NewSquare(5, 7)) {
		t.Error("line e7-f6 must not contain f8")
	}
	if !line[e7][NewSquare(5, 5)].Has(NewSquare(3, 7)) {
		t.Error("line e7-f6 must contain d8")
	}
}
