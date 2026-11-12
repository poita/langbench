package jsoncanon_test

import (
	"errors"
	"strings"
	"testing"

	"github.com/example/jsoncanon"
)

func canon(t *testing.T, in string) (string, bool) {
	t.Helper()
	out, err := jsoncanon.Canonicalize([]byte(in))
	if err != nil {
		var se *jsoncanon.SyntaxError
		if !errors.As(err, &se) {
			t.Fatalf("error %v is not a *SyntaxError", err)
		}
		return "", false
	}
	return string(out), true
}

func TestCanonicalize(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"literals", ` [true,false,null] `, `[true,false,null]`},
		{"empty containers", `{"a":{},"b":[]}`, `{"a":{},"b":[]}`},
		{"worked example 1", `{ "b": [1, 2.50, 1E+3], "a": "héllo\/", "b": null }`, `{"a":"héllo/","b":null}`},
		{"worked example 2", `["😀", -0, 1e-007, 0.0, 1e-0, "tab\tquote\"nul\u0000 AA"]`,
			`["😀",-0,1e-7,0.0,1e0,"tab\tquote\"nul\u0000 AA"]`},
		{"raw specials", `"\u007f\/ 😀"`, "\"\x7f/ \U0001F600\""},
		{"utf16 order", `{"":1,"😀":2,"￿":3,"Z":4}`, "{\"Z\":4,\"😀\":2,\"\":1,\"￿\":3}"},
		{"key order", `{"é":1,"aa":2,"a\u0000":3,"a":4,"":5,"Z":6}`, `{"":5,"Z":6,"a":4,"a\u0000":3,"aa":2,"é":1}`},
		{"duplicate keys by decoded value", `{"a":1,"a":2,"b":3,"a":4}`, `{"a":4,"b":3}`},
		{"escapes", `"\b\f\n\r\t\u001F\u0001\"\\"`, `"\b\f\n\r\t\u001f\u0001\"\\"`},
		{"big integer", `123456789012345678901234567890`, `123456789012345678901234567890`},
		{"neg zero", `-0`, `-0`},
		{"exp upper", `1E5`, `1e5`},
		{"exp plus zeros", `1e+05`, `1e5`},
		{"exp neg zeros", `1e-007`, `1e-7`},
		{"exp neg zero", `1e-0`, `1e0`},
		{"exp all zero", `1E+00`, `1e0`},
		{"frac kept", `1.50`, `1.50`},
		{"neg zero frac", `-0.0`, `-0.0`},
		{"zero exp", `0e0`, `0e0`},
		{"long exp", `2.5E-000789`, `2.5e-789`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := canon(t, tc.in)
			if !ok {
				t.Fatalf("rejected valid input %q", tc.in)
			}
			if got != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestInvalid(t *testing.T) {
	in := []string{
		"", " \n\t\r", "\xEF\xBB\xBF1", "[1,]", "[,1]", "[1 2]", `{"a":1,}`, `{"a"}`, `{a:1}`, `{1:1}`, `{'a':1}`, "'a'",
		"[1] x", "1 2", "[1]\x00", "\x0c1", "\x0b1", " 1", " 1", "\u00851",
		"True", "NaN", "Infinity", "-Infinity", "nul", "tru", "nulll",
		"01", "+1", "-", "1.", ".5", "1e", "1e+", "1E+-5", "1e5e5", "0x1", "- 1", "1 .5", "-a",
		"٢", "1٢", "１", "²",
		"\"a\x01\"", "\"a\tb\"", "\"a\nb\"", `"abc`, `["\`, `"\x"`, `"\U0041"`, `"\'"`, `"\0"`, `"\u12"`, `"\u12G4"`,
		`"\uD800"`, `"\uD800A"`, `"\uD800"`, `"\uD800\uDBFF"`, `"\uD800x"`, `"\uDC00"`, `{"\uD800":1}`,
		`{"a":"\uD800","a":1}`, `{"a":[1,],"a":1}`,
		"\"\xC0\x80\"", "\"\xED\xA0\x80\"", "\"\xF4\x90\x80\x80\"", "\"\xE2\x82\"", "\"\xFF\"", "\"\x80\"",
		"\"\xE0\x80\x80\"", "\"\xF0\x80\x80\x80\"", "\xC3", "[", "{", `{"a"`, `{"a":`, `{"a":1`, `[1`,
	}
	for _, s := range in {
		if out, ok := canon(t, s); ok {
			t.Errorf("accepted %q -> %q", s, out)
		}
	}
}

func TestDepth(t *testing.T) {
	arr := func(n int, inner string) string {
		return strings.Repeat("[", n) + inner + strings.Repeat("]", n)
	}
	if got, ok := canon(t, arr(512, "")); !ok || got != arr(512, "") {
		t.Errorf("depth 512 should be accepted")
	}
	if _, ok := canon(t, arr(513, "")); ok {
		t.Errorf("depth 513 should be rejected")
	}
	if _, ok := canon(t, arr(512, "{}")); ok {
		t.Errorf("empty object at depth 513 should be rejected")
	}
	if _, ok := canon(t, `{"a":`+arr(513, "")+`,"a":1}`); ok {
		t.Errorf("over-deep value under repeated key should be rejected")
	}
	if _, ok := canon(t, strings.Repeat("[", 100000)); ok {
		t.Errorf("unclosed brackets should be rejected")
	}
}

func TestParseTree(t *testing.T) {
	v, err := jsoncanon.Parse([]byte(`{"a":[1,"x\n",true],"a":null}`))
	if err != nil {
		t.Fatal(err)
	}
	if v.Kind != jsoncanon.Object || len(v.Members) != 2 {
		t.Fatalf("unexpected tree: %+v", v)
	}
	arr := v.Members[0].Value
	if arr.Kind != jsoncanon.Array || len(arr.Elems) != 3 ||
		arr.Elems[0].Text != "1" || arr.Elems[1].Text != "x\n" || !arr.Elems[2].Bool {
		t.Errorf("unexpected array: %+v", arr)
	}
	// Serializing must not reorder the tree.
	_ = v.AppendCanonical(nil)
	if v.Members[0].Key != "a" || v.Members[0].Value.Kind != jsoncanon.Array {
		t.Errorf("tree modified by serialization")
	}
}

func TestSyntaxErrorOffset(t *testing.T) {
	_, err := jsoncanon.Parse([]byte("[1, x]"))
	var se *jsoncanon.SyntaxError
	if !errors.As(err, &se) || se.Offset != 4 {
		t.Errorf("got %v, want SyntaxError at offset 4", err)
	}
}

func TestCompareKeys(t *testing.T) {
	ordered := []string{"", "Z", "a", "a\x00", "aa", "é", "߿", "ࠀ", "\U0001F600", "\U0010FFFF", "", "￿"}
	for i, a := range ordered {
		for j, b := range ordered {
			want := 0
			if i < j {
				want = -1
			} else if i > j {
				want = 1
			}
			if got := jsoncanon.CompareKeys(a, b); got != want {
				t.Errorf("CompareKeys(%q,%q)=%d want %d", a, b, got, want)
			}
		}
	}
}

func TestValidUTF8(t *testing.T) {
	good := []string{"", "abc", "é", "€", "😀", "\u0080", "\U0010FFFF", "퟿", ""}
	bad := []string{"\xC0\xAF", "\xC1\xBF", "\xED\xA0\x80", "\xED\xBF\xBF", "\xF4\x90\x80\x80", "\xF5\x80\x80\x80",
		"\xE2\x82", "\xF0\x9F\x98", "\x80", "\xBF", "\xFE", "\xFF", "\xE0\x9F\xBF", "\xF0\x8F\xBF\xBF", "\xC2"}
	for _, s := range good {
		if !jsoncanon.ValidUTF8([]byte(s)) {
			t.Errorf("rejected %q", s)
		}
	}
	for _, s := range bad {
		if jsoncanon.ValidUTF8([]byte(s)) {
			t.Errorf("accepted %q", s)
		}
	}
}

func TestLargeObject(t *testing.T) {
	var b strings.Builder
	b.WriteString("{")
	for i := 0; i < 50000; i++ {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(`"k`)
		b.WriteString(strings.Repeat("x", i%7))
		b.WriteString(string(rune('a' + i%26)))
		b.WriteString(`":`)
		b.WriteString("1")
	}
	b.WriteString("}")
	out, ok := canon(t, b.String())
	if !ok {
		t.Fatal("rejected")
	}
	if len(out) == 0 || out[0] != '{' {
		t.Fatal("bad output")
	}
}

func FuzzCanonicalizeIdempotent(f *testing.F) {
	for _, s := range []string{`{"b":[1,2.50,1E+3],"a":"é😀","b":null}`, `[1e-007,-0,"\u0000"]`, `[`, `"\uD800"`} {
		f.Add([]byte(s))
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		out, err := jsoncanon.Canonicalize(data)
		if err != nil {
			return
		}
		again, err := jsoncanon.Canonicalize(out)
		if err != nil {
			t.Fatalf("canonical output %q rejected: %v", out, err)
		}
		if string(again) != string(out) {
			t.Fatalf("not idempotent: %q -> %q", out, again)
		}
	})
}

func BenchmarkCanonicalize(b *testing.B) {
	doc := []byte(`{"b":[1,2.50,1E+3,"` + strings.Repeat(`é\n`, 1000) + `"],"a":{"x":[[[[]]]],"y":null}}`)
	b.SetBytes(int64(len(doc)))
	for i := 0; i < b.N; i++ {
		if _, err := jsoncanon.Canonicalize(doc); err != nil {
			b.Fatal(err)
		}
	}
}
