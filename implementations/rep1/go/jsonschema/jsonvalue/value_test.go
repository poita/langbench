package jsonvalue

import "testing"

func mustParse(t *testing.T, s string) Value {
	t.Helper()
	v, err := ParseString(s)
	if err != nil {
		t.Fatalf("Parse(%q): %v", s, err)
	}
	return v
}

func TestParseScalars(t *testing.T) {
	if mustParse(t, " null ").Kind() != KindNull {
		t.Error("null")
	}
	if v := mustParse(t, "true"); v.Kind() != KindBool || !v.Bool() {
		t.Error("true")
	}
	if v := mustParse(t, "false"); v.Kind() != KindBool || v.Bool() {
		t.Error("false")
	}
	if v := mustParse(t, "-1.50e2"); v.Kind() != KindNumber || !v.Number().Equal(NumberFromInt64(-150)) {
		t.Errorf("number: %v", v.Number())
	}
}

func TestParseStrings(t *testing.T) {
	tests := map[string]string{
		`"abc"`:          "abc",
		`"a\nb\t\"\\\/"`: "a\nb\t\"\\/",
		`"é"`:            "é",
		`"💩"`:            "💩",
		`"💩x"`:           "💩x",
		`"日本語"`:          "日本語",
		`"\b\f\r"`:       "\b\f\r",
		`""`:             "",
		`"xAy"`:          "xAy",
	}
	for in, want := range tests {
		if got := mustParse(t, in).Str(); got != want {
			t.Errorf("Parse(%s) = %q, want %q", in, got, want)
		}
	}
}

func TestParseContainers(t *testing.T) {
	v := mustParse(t, `{"a":[1,2,{"b":null}],"c":{},"d":[]}`)
	if v.Kind() != KindObject || v.Object().Len() != 3 {
		t.Fatalf("bad object: %+v", v)
	}
	a := v.Object().Get("a")
	if a == nil || len(a.Array()) != 3 {
		t.Fatal("a")
	}
	if b := a.Array()[2].Object().Get("b"); b == nil || b.Kind() != KindNull {
		t.Error("b")
	}
	if v.Object().Get("missing") != nil || v.Object().Has("missing") {
		t.Error("missing key found")
	}
	if ms := v.Object().Members(); ms[0].Key != "a" || ms[2].Key != "d" {
		t.Error("member order not preserved")
	}
}

func TestLargeObjectLookup(t *testing.T) {
	src := "{"
	for i := 0; i < 50; i++ {
		if i > 0 {
			src += ","
		}
		src += `"k` + string(rune('A'+i%26)) + string(rune('a'+i/26)) + `":` + string(rune('0'+i%10))
	}
	src += "}"
	v := mustParse(t, src)
	if v.Object().Len() != 50 {
		t.Fatalf("len = %d", v.Object().Len())
	}
	if !v.Object().Has("kAa") || !v.Object().Has("kXb") || v.Object().Has("kZz") {
		t.Error("indexed lookup wrong")
	}
}

func TestParseErrors(t *testing.T) {
	bad := []string{
		``, `{`, `[1,]`, `{"a":1,}`, `[1 2]`, `{"a" 1}`, `{1:2}`, `tru`, `nul`,
		`"abc`, `"a\qb"`, "\"a\nb\"", `[1] x`, `01`, `1.`, `"\u12"`, `{"a":}`,
	}
	for _, s := range bad {
		if _, err := ParseString(s); err == nil {
			t.Errorf("Parse(%q) succeeded, want error", s)
		}
	}
	_, err := ParseString("[1,")
	if _, ok := err.(*SyntaxError); !ok {
		t.Errorf("error type = %T, want *SyntaxError", err)
	}
}

func TestEqual(t *testing.T) {
	equal := [][2]string{
		{`1`, `1.0`},
		{`1`, `1e0`},
		{`{"a":1,"b":2}`, `{"b":2,"a":1}`},
		{`[1,[2,{"x":3}]]`, `[1.0,[2,{"x":3.0}]]`},
		{`"é"`, `"é"`},
		{`null`, `null`},
		{`{"a":{"b":[]}}`, `{"a":{"b":[]}}`},
	}
	for _, p := range equal {
		a, b := mustParse(t, p[0]), mustParse(t, p[1])
		if !Equal(a, b) || !Equal(b, a) {
			t.Errorf("%s should equal %s", p[0], p[1])
		}
		if Hash(a) != Hash(b) {
			t.Errorf("hash(%s) != hash(%s)", p[0], p[1])
		}
	}
	unequal := [][2]string{
		{`1`, `true`}, {`0`, `false`}, {`"1"`, `1`}, {`null`, `false`},
		{`[1,2]`, `[2,1]`}, {`[1]`, `[1,1]`}, {`{"a":1}`, `{"a":1,"b":2}`},
		{`{"a":1}`, `{"b":1}`}, {`{}`, `[]`}, {`"a"`, `"b"`}, {`1`, `1.5`},
	}
	for _, p := range unequal {
		if Equal(mustParse(t, p[0]), mustParse(t, p[1])) {
			t.Errorf("%s should not equal %s", p[0], p[1])
		}
	}
}

func TestKindString(t *testing.T) {
	if KindObject.String() != "object" || KindNumber.String() != "number" {
		t.Error("Kind.String")
	}
}
