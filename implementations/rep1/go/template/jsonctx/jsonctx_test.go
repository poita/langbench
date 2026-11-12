package jsonctx

import (
	"testing"

	"example.com/template/value"
)

func repr(t *testing.T, v value.Value) string {
	t.Helper()
	s, err := value.Repr(v)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestParse(t *testing.T) {
	d, err := Parse(`{"z": 1, "a": [1.0, 2e2, -3, true, false, null], "s": "x\"\né😀", "o": {}}`)
	if err != nil {
		t.Fatal(err)
	}
	if got := repr(t, d); got != `{'z': 1, 'a': [1.0, 200.0, -3, True, False, None], 's': 'x"\n`+"é😀"+`', 'o': {}}` {
		t.Errorf("got %s", got)
	}
	if keys := d.Keys(); keys[0] != "z" || keys[1] != "a" {
		t.Errorf("member order not preserved: %v", keys)
	}
}

func TestIntegersAndFloats(t *testing.T) {
	for text, want := range map[string]any{"7": int64(7), "-0": int64(0), "7.0": 7.0, "1E2": 100.0, "9223372036854775808": 9223372036854775808.0} {
		v, err := ParseValue(text)
		if err != nil || v != want {
			t.Errorf("ParseValue(%q) = %#v, %v; want %#v", text, v, err, want)
		}
	}
}

func TestErrors(t *testing.T) {
	for _, text := range []string{``, `[1]`, `{"a":}`, `{"a" 1}`, `{"a":1,}`, `{"a":"x}`, `{"a":01}`, `{"a":1} x`, `{"a":"\q"}`, `{"a":tru}`} {
		if _, err := Parse(text); err == nil {
			t.Errorf("Parse(%q) succeeded, want an error", text)
		}
	}
}

func TestLargeObjectLookup(t *testing.T) {
	text := `{"k0":0,"k1":1,"k2":2,"k3":3,"k4":4,"k5":5,"k6":6,"k7":7,"k8":8,"k9":9,"k10":10}`
	d, err := Parse(text)
	if err != nil {
		t.Fatal(err)
	}
	if v, ok := d.Get("k10"); !ok || v != int64(10) {
		t.Errorf("k10 = %v, %v", v, ok)
	}
}
