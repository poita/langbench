package tplerr

import (
	"fmt"
	"testing"
)

func TestKindOf(t *testing.T) {
	err := New(Type, "bad %s", "thing")
	if k, ok := KindOf(err); !ok || k != Type {
		t.Errorf("KindOf = %v, %v", k, ok)
	}
	if k, ok := KindOf(fmt.Errorf("wrapped: %w", err)); !ok || k != Type {
		t.Errorf("KindOf(wrapped) = %v, %v", k, ok)
	}
	if _, ok := KindOf(fmt.Errorf("plain")); ok {
		t.Error("KindOf(plain error) reported a kind")
	}
	if got := err.Error(); got != "template: type error: bad thing" {
		t.Errorf("Error() = %q", got)
	}
}
