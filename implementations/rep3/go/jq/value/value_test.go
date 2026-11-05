package value

import "testing"

func mustParse(t *testing.T, s string) Value {
	t.Helper()
	v, err := ParseString(s)
	if err != nil {
		t.Fatalf("Parse(%q): %v", s, err)
	}
	return v
}

func TestParseEncodeRoundTrip(t *testing.T) {
	cases := []string{
		`null`, `true`, `false`, `0`, `-12`, `1.5`, `0.125`, `3086419725308.5`,
		`"a\"b\\c\n\t"`, `[]`, `{}`, `[1,[2,[3]]]`, `{"z":1,"a":{"y":[true,null]}}`,
		`"é€😀"`,
	}
	for _, c := range cases {
		if got := JSON(mustParse(t, c)); got != c {
			t.Errorf("round trip of %s gave %s", c, got)
		}
	}
}

func TestParseWhitespaceAndEscapes(t *testing.T) {
	v := mustParse(t, " \t\r\n{ \"a\" : [ 1 , 2 ] ,\"b\":\"\\u00e9\\ud83d\\ude00\\/\\b\\f\" }\n")
	if got, want := JSON(v), "{\"a\":[1,2],\"b\":\"é😀/\\b\\f\"}"; got != want {
		t.Errorf("got %s want %s", got, want)
	}
}

func TestParseKeyOrder(t *testing.T) {
	v := mustParse(t, `{"b":1,"a":2,"c":3}`)
	if got := JSON(v); got != `{"b":1,"a":2,"c":3}` {
		t.Errorf("key order lost: %s", got)
	}
	keys := v.Obj().SortedKeys()
	if len(keys) != 3 || keys[0] != "a" || keys[2] != "c" {
		t.Errorf("SortedKeys = %v", keys)
	}
}

func TestParseErrors(t *testing.T) {
	for _, s := range []string{``, `{`, `[1,]`, `{"a"}`, `01`, `1.`, `"abc`, `tru`, `[1] x`, `"\x"`, `{"a":1,}`} {
		if _, err := ParseString(s); err == nil {
			t.Errorf("Parse(%q) succeeded, want error", s)
		}
	}
}

func TestNumbers(t *testing.T) {
	cases := map[string]string{
		`1e2`: `100`, `0.1`: `0.1`, `-0.5`: `-0.5`, `1000000000000`: `1000000000000`,
		`9007199254740991`: `9007199254740991`, `2.25`: `2.25`, `123456789.123`: `123456789.123`,
	}
	for in, want := range cases {
		if got := JSON(mustParse(t, in)); got != want {
			t.Errorf("%s -> %s, want %s", in, got, want)
		}
	}
	if f, ok := ParseNumber("-2.5"); !ok || f != -2.5 {
		t.Errorf("ParseNumber(-2.5) = %v %v", f, ok)
	}
	for _, s := range []string{"", "abc", "1x", " 1", "1 ", "+1", "."} {
		if _, ok := ParseNumber(s); ok {
			t.Errorf("ParseNumber(%q) succeeded", s)
		}
	}
}

func TestQuoting(t *testing.T) {
	got := string(AppendQuoted(nil, "a\x01\x7f\"\\/<>&é"))
	if want := "\"a\\u0001\\u007f\\\"\\\\/<>&é\""; got != want {
		t.Errorf("got %s want %s", got, want)
	}
}

func TestCompareOrder(t *testing.T) {
	order := []string{
		`null`, `false`, `true`, `-1`, `0`, `1.5`, `""`, `"Z"`, `"a"`, `"ab"`, `"b"`, `"é"`,
		`[]`, `[1]`, `[1,2]`, `[2]`, `{}`, `{"a":1}`, `{"a":2}`, `{"b":0}`,
	}
	for i := range order {
		for j := range order {
			a, b := mustParse(t, order[i]), mustParse(t, order[j])
			want := 0
			if i < j {
				want = -1
			} else if i > j {
				want = 1
			}
			if got := Compare(a, b); got != want {
				t.Errorf("Compare(%s, %s) = %d, want %d", order[i], order[j], got, want)
			}
		}
	}
}

func TestEqualIgnoresKeyOrder(t *testing.T) {
	a, b := mustParse(t, `{"a":1,"b":[1,2]}`), mustParse(t, `{"b":[1,2],"a":1}`)
	if !Equal(a, b) {
		t.Error("objects with different key order should be equal")
	}
	if Equal(a, mustParse(t, `{"a":1,"b":[1,3]}`)) {
		t.Error("different objects reported equal")
	}
}

func TestObjectSetAndMerge(t *testing.T) {
	o := NewObject(0)
	o.Set("a", Number(1))
	o.Set("b", Number(2))
	o.Set("a", Number(3))
	if got := JSON(ObjectValue(o)); got != `{"a":3,"b":2}` {
		t.Errorf("Set: %s", got)
	}
	x := mustParse(t, `{"z":1,"a":2}`).Obj()
	y := mustParse(t, `{"m":3,"z":9}`).Obj()
	if got := JSON(ObjectValue(Merge(x, y))); got != `{"z":9,"a":2,"m":3}` {
		t.Errorf("Merge: %s", got)
	}
	if got := JSON(ObjectValue(x)); got != `{"z":1,"a":2}` {
		t.Errorf("Merge mutated its operand: %s", got)
	}
	d := DeepMerge(mustParse(t, `{"a":{"b":1,"c":2},"d":1}`).Obj(), mustParse(t, `{"a":{"b":9},"d":{"e":1}}`).Obj())
	if got := JSON(ObjectValue(d)); got != `{"a":{"b":9,"c":2},"d":{"e":1}}` {
		t.Errorf("DeepMerge: %s", got)
	}
}

func TestLargeObjectLookup(t *testing.T) {
	o := NewObject(0)
	for i := 0; i < 100; i++ {
		o.Set(string(rune('A'+i%26))+string(rune('a'+i/26)), Number(float64(i)))
	}
	for i := 0; i < 100; i++ {
		v, ok := o.Get(string(rune('A'+i%26)) + string(rune('a'+i/26)))
		if !ok || v.Float() != float64(i) {
			t.Fatalf("lookup %d failed", i)
		}
	}
	if o.Has("nope") {
		t.Error("Has(nope)")
	}
}
