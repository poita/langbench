package jsonvalue

import (
	"strings"
	"testing"
)

func mustParse(t *testing.T, s string) Value {
	t.Helper()
	v, err := ParseString(s)
	if err != nil {
		t.Fatalf("ParseString(%q): %v", s, err)
	}
	return v
}

func TestParseRoundTrip(t *testing.T) {
	tests := []struct{ in, want string }{
		{`null`, `null`},
		{` true `, `true`},
		{`[1, 2.50, -0, 1e2]`, `[1,2.5,0,100]`},
		{`{"b": [], "a": {}}`, `{"b":[],"a":{}}`},
		{`"aé\n💩"`, "\"aé\\n\U0001F4A9\""},
		{`"\"\\\/\b\f\t"`, `"\"\\/\u0008\u000c\t"`},
	}
	for _, tc := range tests {
		got := mustParse(t, tc.in).String()
		if got != tc.want {
			t.Errorf("Parse(%q).String() = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestParseErrors(t *testing.T) {
	bad := []string{
		``, `{`, `[1,]`, `{"a":1,}`, `{"a" 1}`, `01`, `1.`, `.5`, `-`, `1e`, `+1`,
		`"abc`, "\"a\x01\"", `"\x"`, `"\ud800"`, `"\udc00"`, `"\ud800A"`,
		`tru`, `nul`, `[1] 2`, `{"a":1,"a":2}`, `{"a":1,"b":2,"c":3,"d":4,"e":5,"f":6,"g":7,"h":8,"i":9,"a":0}`,
		"\"\xff\"", `1e999999999`,
	}
	for _, s := range bad {
		if v, err := ParseString(s); err == nil {
			t.Errorf("ParseString(%q) = %v, want error", s, v)
		}
	}
}

func TestObjectOrderAndLookup(t *testing.T) {
	var sb strings.Builder
	sb.WriteString("{")
	for i := 0; i < 20; i++ {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(`"k` + itoa(i) + `":` + itoa(i))
	}
	sb.WriteString("}")
	o, ok := mustParse(t, sb.String()).Object()
	if !ok || o.Len() != 20 {
		t.Fatalf("bad object: %v %d", ok, o.Len())
	}
	for i := 0; i < 20; i++ {
		k, _ := o.At(i)
		if k != "k"+itoa(i) {
			t.Fatalf("member %d has key %q", i, k)
		}
		v, ok := o.Get(k)
		n, _ := v.Number()
		if got, _ := n.Int64(); !ok || got != int64(i) {
			t.Fatalf("Get(%q) = %v", k, v)
		}
	}
	if o.Has("missing") {
		t.Error(`Has("missing") = true`)
	}
}

func TestNumberEquality(t *testing.T) {
	same := [][]string{
		{"1", "1.0", "1.00", "1e0", "10e-1", "0.1e1"},
		{"100", "1e2", "1E+2", "100.000"},
		{"0", "-0", "0.0", "0e5", "-0.000e-3"},
		{"-1.5", "-15e-1", "-0.15e1"},
	}
	for _, group := range same {
		first, _ := mustParse(t, group[0]).Number()
		for _, s := range group[1:] {
			n, _ := mustParse(t, s).Number()
			if !first.Equal(n) || first.Cmp(n) != 0 {
				t.Errorf("%s and %s should be equal", group[0], s)
			}
			if mustParse(t, group[0]).Hash() != mustParse(t, s).Hash() {
				t.Errorf("%s and %s should hash alike", group[0], s)
			}
		}
	}
}

func TestNumberCmp(t *testing.T) {
	tests := []struct {
		a, b string
		want int
	}{
		{"1", "2", -1},
		{"-1", "1", -1},
		{"1e309", "1e308", 1},
		{"1e-400", "0", 1},
		{"-1e-400", "0", -1},
		{"0.30000000000000004", "0.3", 1},
		{"123456789012345678901234567890", "123456789012345678901234567891", -1},
		{"1e400", "9.99999e399", 1},
		{"-1e400", "-9.99999e399", -1},
		{"0.0021", "0.0021000", 0},
	}
	for _, tc := range tests {
		a, _ := mustParse(t, tc.a).Number()
		b, _ := mustParse(t, tc.b).Number()
		if got := a.Cmp(b); got != tc.want {
			t.Errorf("Cmp(%s, %s) = %d, want %d", tc.a, tc.b, got, tc.want)
		}
		if got := b.Cmp(a); got != -tc.want {
			t.Errorf("Cmp(%s, %s) = %d, want %d", tc.b, tc.a, got, -tc.want)
		}
	}
}

func TestNumberIsInteger(t *testing.T) {
	for s, want := range map[string]bool{"1": true, "1.0": true, "1e2": true, "-0": true, "0.0": true, "1.5": false, "1e-1": false, "10e-1": true} {
		n, _ := mustParse(t, s).Number()
		if n.IsInteger() != want {
			t.Errorf("IsInteger(%s) = %v, want %v", s, !want, want)
		}
	}
}

func TestIsMultipleOf(t *testing.T) {
	tests := []struct {
		a, b string
		want bool
	}{
		{"10", "5", true},
		{"10", "3", false},
		{"0.3", "0.0001", true},
		{"0.0021", "0.0001", true},
		{"0.00751", "0.0001", false},
		{"4.5", "1.5", true},
		{"4.5", "0.5", true},
		{"0", "7", true},
		{"1e308", "1e-5", true},
		{"1e-400", "1e400", false},
		{"1e400", "1e-400", true},
		{"7.5", "2", false},
		{"-6", "3", true},
		{"12", "-4", true},
	}
	for _, tc := range tests {
		a, _ := mustParse(t, tc.a).Number()
		b, _ := mustParse(t, tc.b).Number()
		if got := a.IsMultipleOf(b); got != tc.want {
			t.Errorf("IsMultipleOf(%s, %s) = %v, want %v", tc.a, tc.b, got, tc.want)
		}
	}
}

func TestInt64(t *testing.T) {
	for s, want := range map[string]struct {
		v  int64
		ok bool
	}{
		"5":                    {5, true},
		"-5":                   {-5, true},
		"2e1":                  {20, true},
		"2.0":                  {2, true},
		"2.5":                  {0, false},
		"9223372036854775807":  {9223372036854775807, true},
		"9223372036854775808":  {0, false},
		"-9223372036854775808": {-9223372036854775808, true},
		"1e30":                 {0, false},
	} {
		n, _ := mustParse(t, s).Number()
		if v, ok := n.Int64(); v != want.v || ok != want.ok {
			t.Errorf("Int64(%s) = %d, %v; want %d, %v", s, v, ok, want.v, want.ok)
		}
	}
}

func TestEqual(t *testing.T) {
	equal := [][2]string{
		{`1`, `1.0`},
		{`{"a":1,"b":[2,3]}`, `{"b":[2,3.0],"a":1.000}`},
		{`"é"`, `"é"`},
		{`[]`, `[]`},
		{`null`, `null`},
	}
	for _, p := range equal {
		a, b := mustParse(t, p[0]), mustParse(t, p[1])
		if !Equal(a, b) || !Equal(b, a) {
			t.Errorf("%s should equal %s", p[0], p[1])
		}
		if a.Hash() != b.Hash() {
			t.Errorf("%s and %s should hash alike", p[0], p[1])
		}
	}
	different := [][2]string{
		{`1`, `true`},
		{`0`, `false`},
		{`"1"`, `1`},
		{`[1]`, `[1,1]`},
		{`{"a":1}`, `{"a":1,"b":1}`},
		{`{"a":1}`, `{"b":1}`},
		{`{"a":1,"b":2}`, `{"a":1,"b":3}`},
		{`[]`, `{}`},
		{`null`, `false`},
		{`[1,2]`, `[2,1]`},
	}
	for _, p := range different {
		if Equal(mustParse(t, p[0]), mustParse(t, p[1])) {
			t.Errorf("%s should differ from %s", p[0], p[1])
		}
	}
}

func TestDeepNesting(t *testing.T) {
	const depth = 5000
	s := strings.Repeat("[", depth) + strings.Repeat("]", depth)
	if _, err := ParseString(s); err != nil {
		t.Fatal(err)
	}
}

func TestBigNumbers(t *testing.T) {
	digits := strings.Repeat("9", 400)
	n, err := ParseNumber(digits + "e-400")
	if err != nil {
		t.Fatal(err)
	}
	one, _ := ParseNumber("1")
	if n.Cmp(one) >= 0 {
		t.Error("0.999... should be < 1")
	}
	if _, err := ParseNumber("1x"); err == nil {
		t.Error("ParseNumber(1x) should fail")
	}
}
