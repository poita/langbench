package diag

import "testing"

func TestErrorText(t *testing.T) {
	if got := Bare(NoDefault).Error(); got != "E_NO_DEFAULT" {
		t.Errorf("got %q", got)
	}
	if got := New(Cycle, "%s -> %s", "a", "a").Error(); got != "E_CYCLE a -> a" {
		t.Errorf("got %q", got)
	}
	var err error = &Error{Kind: Abort, Detail: "x"}
	if e, ok := err.(*Error); !ok || e.Kind != Abort {
		t.Error("type assertion")
	}
}
