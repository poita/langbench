package value_test

import (
	"strings"
	"testing"

	"github.com/peter/jq/value"
)

func mustParse(t *testing.T, s string) value.Value {
	t.Helper()
	v, err := value.Parse(s)
	if err != nil {
		t.Fatalf("Parse(%q): %v", s, err)
	}
	return v
}

func TestParseRoundTrip(t *testing.T) {
	cases := []string{
		`null`, `true`, `false`, `0`, `-12`, `1.5`, `0.125`, `3086419725308.5`,
		`1000000000000`, `""`, `"a b"`, `[]`, `{}`, `[1,[2,[3]]]`,
		`{"b":1,"a":2,"c":{"x":[]}}`, `"é€😀"`, `"\u007f"`,
	}
	for _, c := range cases {
		if got := value.JSON(mustParse(t, c)); got != c {
			t.Errorf("round trip of %s gave %s", c, got)
		}
	}
}

func TestParseStringEscapes(t *testing.T) {
	v := mustParse(t, `"\" \\ \/ \b \f \n \r \t é 😀 \u0001"`)
	want := "\" \\ / \b \f \n \r \t é 😀 \x01"
	if v.Str() != want {
		t.Errorf("got %q, want %q", v.Str(), want)
	}
	if got := value.JSON(v); got != `"\" \\ / \b \f \n \r \t é 😀 \u0001"` {
		t.Errorf("serialised as %s", got)
	}
}

func TestParseWhitespaceAndNumbers(t *testing.T) {
	v := mustParse(t, " \t\r\n[ 1 ,\n 2.50 , -0.5 , 1e2, 12345678901234567 ] \n")
	got := value.JSON(v)
	if got != `[1,2.5,-0.5,100,12345678901234568]` {
		t.Errorf("got %s", got)
	}
}

func TestParseErrors(t *testing.T) {
	bad := []string{``, `[`, `[1,]`, `{"a"}`, `{"a":1,}`, `tru`, `01`, `1.`, `"abc`,
		`"\x"`, `[1] 2`, `{1:2}`, "\"a\nb\""}
	for _, s := range bad {
		if _, err := value.Parse(s); err == nil {
			t.Errorf("Parse(%q) succeeded, want error", s)
		}
	}
}

func TestParseDeepNestingFails(t *testing.T) {
	s := strings.Repeat("[", 20000) + strings.Repeat("]", 20000)
	if _, err := value.Parse(s); err == nil {
		t.Error("expected nesting error")
	}
}

func TestParseNumber(t *testing.T) {
	for in, want := range map[string]float64{
		"0": 0, "12": 12, "-2.5": -2.5, "3.25": 3.25, "0.1": 0.1,
		"123456789.123456": 123456789.123456, "1e3": 1000, "1.5E-2": 0.015,
		"9007199254740993": 9007199254740992,
	} {
		got, err := value.ParseNumber(in)
		if err != nil || got != want {
			t.Errorf("ParseNumber(%q) = %v, %v; want %v", in, got, err, want)
		}
	}
	for _, in := range []string{"", " 1", "1 ", "abc", "1.", ".5", "+1", "007", "-", "0x10"} {
		if _, err := value.ParseNumber(in); err == nil {
			t.Errorf("ParseNumber(%q) succeeded", in)
		}
	}
}

func TestAppendNumber(t *testing.T) {
	for f, want := range map[float64]string{
		0: "0", 3: "3", -12: "-12", 1.5: "1.5", 0.125: "0.125",
		1e12: "1000000000000", 0.001: "0.001", 3086419725308.5: "3086419725308.5",
	} {
		if got := string(value.AppendNumber(nil, f)); got != want {
			t.Errorf("AppendNumber(%v) = %s, want %s", f, got, want)
		}
	}
}

func TestObjectOrderAndLookup(t *testing.T) {
	v := mustParse(t, `{"z":1,"a":2,"m":3}`)
	o := v.Object()
	if got := strings.Join(o.SortedKeys(), ","); got != "a,m,z" {
		t.Errorf("sorted keys %s", got)
	}
	if x, ok := o.Get("a"); !ok || x.Float() != 2 {
		t.Errorf("Get(a) = %v, %v", x, ok)
	}
	if _, ok := o.Get("q"); ok {
		t.Error("Get(q) found a key")
	}
	if value.JSON(v) != `{"z":1,"a":2,"m":3}` {
		t.Errorf("order changed: %s", value.JSON(v))
	}
}

func TestObjectBuilderSetKeepsPosition(t *testing.T) {
	b := value.NewObjectBuilder(0)
	b.Set("a", value.Number(1))
	b.Set("b", value.Number(2))
	b.Set("a", value.Number(3))
	if got := value.JSON(b.Build()); got != `{"a":3,"b":2}` {
		t.Errorf("got %s", got)
	}
}

func TestObjectBuilderCopyDoesNotMutateSource(t *testing.T) {
	src := mustParse(t, `{"a":1}`)
	b := src.Object().Builder(1)
	b.Set("a", value.Number(9))
	b.Set("b", value.Number(2))
	_ = b.Build()
	if value.JSON(src) != `{"a":1}` {
		t.Errorf("source mutated: %s", value.JSON(src))
	}
}

func TestLargeObjectUsesIndex(t *testing.T) {
	b := value.NewObjectBuilder(0)
	for i := 0; i < 100; i++ {
		b.Set(strings.Repeat("k", i+1), value.Number(float64(i)))
	}
	b.Set(strings.Repeat("k", 50), value.Number(-1))
	o := b.Build().Object()
	if o.Len() != 100 {
		t.Fatalf("len %d", o.Len())
	}
	if x, _ := o.Get(strings.Repeat("k", 50)); x.Float() != -1 {
		t.Errorf("replaced value = %v", x.Float())
	}
	if !o.Has(strings.Repeat("k", 100)) || o.Has("x") {
		t.Error("Has wrong")
	}
	if o.Entries()[49].Key != strings.Repeat("k", 50) {
		t.Error("position changed")
	}
}

func TestCompareTypeOrder(t *testing.T) {
	ordered := []string{`null`, `false`, `true`, `-1`, `0`, `2.5`, `""`, `"Z"`, `"a"`, `"ab"`, `"b"`, `"é"`,
		`[]`, `[1]`, `[1,2]`, `[2]`, `{}`, `{"a":1}`, `{"a":2}`, `{"a":1,"b":0}`, `{"b":1}`}
	for i := range ordered {
		for j := range ordered {
			a, b := mustParse(t, ordered[i]), mustParse(t, ordered[j])
			got := value.Compare(a, b)
			want := 0
			if i < j {
				want = -1
			} else if i > j {
				want = 1
			}
			if (got < 0) != (want < 0) || (got > 0) != (want > 0) {
				t.Errorf("Compare(%s, %s) = %d, want sign %d", ordered[i], ordered[j], got, want)
			}
		}
	}
}

func TestEqualIgnoresKeyOrder(t *testing.T) {
	a := mustParse(t, `{"a":1,"b":[1,2]}`)
	b := mustParse(t, `{"b":[1,2],"a":1}`)
	if !value.Equal(a, b) {
		t.Error("objects with different key order should be equal")
	}
	if value.Equal(a, mustParse(t, `{"a":1,"b":[1,3]}`)) {
		t.Error("different values compared equal")
	}
}

func TestScalarAccessors(t *testing.T) {
	if value.Null.Truthy() || value.False.Truthy() {
		t.Error("null/false are falsy")
	}
	for _, v := range []value.Value{value.Number(0), value.String(""), value.Array(nil), value.True} {
		if !v.Truthy() {
			t.Errorf("%s should be truthy", value.JSON(v))
		}
	}
	if value.Number(1).TypeName() != "number" || value.True.TypeName() != "boolean" {
		t.Error("type names")
	}
}
