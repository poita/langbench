package value

import (
	"strings"
	"testing"
)

func TestParseAndMarshalRoundTrip(t *testing.T) {
	cases := []string{
		`null`, `true`, `false`, `0`, `-12`, `1.5`, `3086419725308.5`,
		`"a\"b\\c\n\t"`, `"é😀"`, `[]`, `{}`, `[1,[2,[3]]]`,
		`{"z":1,"a":{"y":[true,null],"b":"x"}}`,
	}
	for _, in := range cases {
		v, err := ParseString(in)
		if err != nil {
			t.Errorf("Parse(%s): %v", in, err)
			continue
		}
		if got := String(v); got != in {
			t.Errorf("round trip of %s gave %s", in, got)
		}
	}
}

func TestParseEscapes(t *testing.T) {
	v, err := ParseString(` "é😀\/\b\f\u001F" `)
	if err != nil {
		t.Fatal(err)
	}
	if want := "é😀/\b\f\x1f"; v != want {
		t.Errorf("got %q, want %q", v, want)
	}
	if got := String(v); got != `"é😀/\b\f\u001f"` {
		t.Errorf("encoded %s", got)
	}
}

func TestEncodeEscapes(t *testing.T) {
	got := String("\x00\x07\x1f\x7f</& ")
	want := `"\u0000\u0007\u001f\u007f</&` + " " + `"`
	if got != want {
		t.Errorf("got %s want %s", got, want)
	}
}

func TestParseErrors(t *testing.T) {
	for _, in := range []string{``, `[1,]`, `{"a"}`, `01`, `1.`, `"abc`, `[1] x`, `tru`, `{"a":1,}`, `"\x"`, `-`} {
		if _, err := ParseString(in); err == nil {
			t.Errorf("Parse(%q) succeeded, want error", in)
		}
	}
}

func TestParseDeepNestingIsRejected(t *testing.T) {
	in := strings.Repeat("[", maxDepth+10)
	if _, err := ParseString(in); err == nil {
		t.Error("expected an error for pathological nesting")
	}
}

func TestNumberFormatting(t *testing.T) {
	cases := map[float64]string{
		0: "0", 3: "3", -12: "-12", 1e12: "1000000000000", 1.5: "1.5", 0.125: "0.125",
		3086419725308.5: "3086419725308.5", 0.001: "0.001", 1e-7: "1e-07",
		9007199254740991: "9007199254740991",
	}
	for f, want := range cases {
		if got := FormatNumber(f); got != want {
			t.Errorf("FormatNumber(%v) = %s, want %s", f, got, want)
		}
	}
}

func TestParseNumber(t *testing.T) {
	good := map[string]float64{"12": 12, "-2.5": -2.5, "3.25": 3.25, "0": 0, "1e2": 100}
	for s, want := range good {
		if got, ok := ParseNumber(s); !ok || got != want {
			t.Errorf("ParseNumber(%q) = %v, %v", s, got, ok)
		}
	}
	for _, s := range []string{"", " 1", "1 ", "abc", "007", "+1", "nan", "0x10", "1_0", "."} {
		if _, ok := ParseNumber(s); ok {
			t.Errorf("ParseNumber(%q) succeeded", s)
		}
	}
}

func TestCompareOrdering(t *testing.T) {
	ordered := []string{
		`null`, `false`, `true`, `-5`, `0`, `1.5`, `""`, `"a"`, `"ab"`, `"b"`, `"c"`, `"é"`,
		`[]`, `[0]`, `[0,0]`, `[1]`, `{}`, `{"a":1}`, `{"a":2}`, `{"a":0,"b":0}`, `{"b":0}`,
	}
	var vals []Value
	for _, s := range ordered {
		v, err := ParseString(s)
		if err != nil {
			t.Fatal(err)
		}
		vals = append(vals, v)
	}
	for i := range vals {
		for j := range vals {
			want := cmpInt(i, j)
			if got := Compare(vals[i], vals[j]); got != want {
				t.Errorf("Compare(%s, %s) = %d, want %d", ordered[i], ordered[j], got, want)
			}
		}
	}
}

func TestEqualIgnoresKeyOrder(t *testing.T) {
	a, _ := ParseString(`{"a":1,"b":[1,2]}`)
	b, _ := ParseString(`{"b":[1,2],"a":1}`)
	if !Equal(a, b) {
		t.Error("objects with different key order should be equal")
	}
	if !Equal(1.0, 1.5-0.5) {
		t.Error("1 should equal 1.5-0.5")
	}
}

func TestObjectBuilderKeepsFirstPosition(t *testing.T) {
	b := NewBuilder(0)
	b.Set("a", 1.0)
	b.Set("b", 2.0)
	b.Set("a", 3.0)
	if got := String(b.Build()); got != `{"a":3,"b":2}` {
		t.Errorf("got %s", got)
	}
}

func TestObjectManyKeysUsesIndex(t *testing.T) {
	b := NewBuilder(0)
	for i := 0; i < 100; i++ {
		b.Set(String(float64(i)), float64(i))
	}
	b.Set("5", "five")
	o := b.Build()
	if o.Len() != 100 {
		t.Fatalf("len = %d", o.Len())
	}
	if v, ok := o.Get("5"); !ok || v != "five" {
		t.Errorf("Get(5) = %v, %v", v, ok)
	}
	if _, ok := o.Get("missing"); ok {
		t.Error("unexpected key")
	}
	keys := o.SortedKeys()
	for i := 1; i < len(keys); i++ {
		if keys[i-1] >= keys[i] {
			t.Fatalf("keys not sorted: %v", keys)
		}
	}
}

func TestMerge(t *testing.T) {
	a, _ := ParseString(`{"z":1,"a":2}`)
	b, _ := ParseString(`{"m":3,"z":9}`)
	if got := String(Merge(a.(*Object), b.(*Object))); got != `{"z":9,"a":2,"m":3}` {
		t.Errorf("Merge = %s", got)
	}
	if got := String(a); got != `{"z":1,"a":2}` {
		t.Errorf("Merge mutated its operand: %s", got)
	}
	x, _ := ParseString(`{"a":{"b":1,"c":2},"d":1}`)
	y, _ := ParseString(`{"a":{"b":5},"d":{"e":1}}`)
	if got := String(DeepMerge(x.(*Object), y.(*Object))); got != `{"a":{"b":5,"c":2},"d":{"e":1}}` {
		t.Errorf("DeepMerge = %s", got)
	}
}

func TestMergeLargeObjects(t *testing.T) {
	a := NewBuilder(0)
	b := NewBuilder(0)
	for i := 0; i < 50; i++ {
		a.Set(String(float64(i)), float64(i))
		b.Set(String(float64(i+25)), "b")
	}
	m := Merge(a.Build(), b.Build())
	if m.Len() != 75 {
		t.Fatalf("len = %d", m.Len())
	}
	if v, _ := m.Get("30"); v != "b" {
		t.Errorf("m[30] = %v", v)
	}
	if v, _ := m.Get("10"); v != 10.0 {
		t.Errorf("m[10] = %v", v)
	}
}

func TestSortIsStable(t *testing.T) {
	keys := []Value{1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0}
	perm := SortedOrder(keys)
	want := []int{1, 3, 5, 7, 9, 11, 0, 2, 4, 6, 8, 10}
	for i := range want {
		if perm[i] != want[i] {
			t.Fatalf("perm = %v, want %v", perm, want)
		}
	}
}

func TestSortComparisonCount(t *testing.T) {
	n := 4096
	vals := make([]Value, n)
	for i := range vals {
		vals[i] = float64((i * 7919) % n)
	}
	sorted := Sort(vals)
	for i := 1; i < n; i++ {
		if Compare(sorted[i-1], sorted[i]) > 0 {
			t.Fatal("not sorted")
		}
	}
}
