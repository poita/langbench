package diag

import "testing"

func TestErrorText(t *testing.T) {
	e := New(TypeMismatch, Pos{Line: 3, Col: 15})
	if got, want := e.Error(), "error: type-mismatch at 3:15"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}
