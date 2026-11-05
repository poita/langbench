package cube

import (
	"reflect"
	"testing"
)

func TestMoveStrings(t *testing.T) {
	want := []string{"U", "U2", "U'", "R", "R2", "R'", "F", "F2", "F'",
		"D", "D2", "D'", "L", "L2", "L'", "B", "B2", "B'"}
	for i, w := range want {
		m := Move(i)
		if m.String() != w {
			t.Errorf("Move(%d) = %q, want %q", i, m.String(), w)
		}
		back, err := ParseMove(w)
		if err != nil || back != m {
			t.Errorf("ParseMove(%q) = %v, %v", w, back, err)
		}
	}
}

func TestParseMovesErrors(t *testing.T) {
	for _, s := range []string{"R2'", "r", "R'2", "X", "R3", "RR", "R U x"} {
		if _, err := ParseMoves(s); err == nil {
			t.Errorf("ParseMoves(%q) succeeded", s)
		}
	}
	m, err := ParseMoves("")
	if err != nil || len(m) != 0 {
		t.Errorf("ParseMoves(\"\") = %v, %v", m, err)
	}
}

func TestFormatMoves(t *testing.T) {
	in := "R U' F2 B L' D"
	m, err := ParseMoves(in)
	if err != nil {
		t.Fatal(err)
	}
	if got := FormatMoves(m); got != in {
		t.Errorf("FormatMoves = %q", got)
	}
	if got := FormatMoves(nil); got != "" {
		t.Errorf("FormatMoves(nil) = %q", got)
	}
}

func TestMoveAccessors(t *testing.T) {
	m := NewMove(L, 3)
	if m.Face() != L || m.Turns() != 3 || m.String() != "L'" || m.Inverse() != NewMove(L, 1) {
		t.Errorf("unexpected accessors for %v", m)
	}
	if !NewMove(B, 2).IsHalfTurn() || NewMove(B, 1).IsHalfTurn() {
		t.Error("IsHalfTurn wrong")
	}
	if U.Opposite() != D || R.Opposite() != L || F.Opposite() != B {
		t.Error("Opposite wrong")
	}
}

func TestSimplify(t *testing.T) {
	tests := []struct{ in, want string }{
		{"", ""},
		{"R R'", ""},
		{"R R", "R2"},
		{"R R R", "R'"},
		{"R R R R U", "U"},
		{"R U U' R'", ""},
		{"R2 R' U", "R U"},
		{"R U F", "R U F"},
	}
	for _, tc := range tests {
		got := Simplify(mustParse(t, tc.in))
		want := mustParse(t, tc.want)
		if !reflect.DeepEqual(got, want) && !(len(got) == 0 && len(want) == 0) {
			t.Errorf("Simplify(%q) = %v, want %v", tc.in, FormatMoves(got), tc.want)
		}
	}
}

func TestSimplifyPreservesState(t *testing.T) {
	seq := mustParse(t, "R R U U2 F' F B B L2 L2 D D' D R")
	if Scrambled(seq) != Scrambled(Simplify(seq)) {
		t.Error("Simplify changed the cube state")
	}
}
