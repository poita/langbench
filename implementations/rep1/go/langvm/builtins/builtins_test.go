package builtins

import "testing"

func TestCount(t *testing.T) {
	if len(Specs) != 132 {
		t.Fatalf("expected 132 built-ins, got %d", len(Specs))
	}
	for name, id := range IDs {
		if Specs[id].Name != name {
			t.Errorf("id mismatch for %s", name)
		}
	}
}
