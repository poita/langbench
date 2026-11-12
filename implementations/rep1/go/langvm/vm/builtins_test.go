package vm

import (
	"testing"

	"langvm/builtins"
)

// Every built-in listed in the builtins package must have an implementation.
func TestAllBuiltinsImplemented(t *testing.T) {
	if len(builtins.All) != 132 {
		t.Fatalf("expected 132 built-ins, have %d", len(builtins.All))
	}
	for i, s := range builtins.All {
		if builtinTable[i] == nil {
			t.Errorf("built-in %s has no implementation", s.Name)
		}
	}
	if len(impls) != len(builtins.All) {
		t.Errorf("%d implementations for %d built-ins", len(impls), len(builtins.All))
	}
}

func TestMapInsertionOrder(t *testing.T) {
	m := newMap()
	for i := int64(0); i < 100; i++ {
		m.set(i, i)
	}
	for i := int64(0); i < 100; i += 2 {
		m.del(i)
	}
	m.set(int64(0), int64(7))
	var keys []int64
	for _, e := range m.entries {
		if !e.dead {
			keys = append(keys, e.key.(int64))
		}
	}
	if len(keys) != 51 || keys[0] != 1 || keys[len(keys)-1] != 0 || m.live != 51 {
		t.Errorf("unexpected order %v (live %d)", keys, m.live)
	}
	if v, ok := m.get(int64(0)); !ok || v.(int64) != 7 {
		t.Errorf("get after reinsert: %v %v", v, ok)
	}
}

func TestStringKeys(t *testing.T) {
	m := newMap()
	m.set([]rune("é"), int64(1))
	if _, ok := m.get([]rune("é")); !ok {
		t.Error("string key lookup failed")
	}
	if !equal(m, m.copyMap()) {
		t.Error("copy not equal")
	}
}
