package jsonpointer

import (
	"errors"
	"reflect"
	"testing"

	"example.com/jsonschema/jsonvalue"
)

// The document and pointers of RFC 6901 section 5.
const rfcDoc = `{
  "foo": ["bar", "baz"],
  "": 0,
  "a/b": 1,
  "c%d": 2,
  "e^f": 3,
  "g|h": 4,
  "i\\j": 5,
  "k\"l": 6,
  " ": 7,
  "m~n": 8
}`

func TestEvalRFC6901(t *testing.T) {
	doc, err := jsonvalue.ParseString(rfcDoc)
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct{ ptr, want string }{
		{"", ""}, // whole document; checked separately
		{"/foo", `["bar","baz"]`},
		{"/foo/0", `"bar"`},
		{"/", `0`},
		{"/a~1b", `1`},
		{"/c%d", `2`},
		{"/e^f", `3`},
		{"/g|h", `4`},
		{`/i\j`, `5`},
		{`/k"l`, `6`},
		{"/ ", `7`},
		{"/m~0n", `8`},
	}
	for _, tc := range tests {
		got, err := Eval(doc, tc.ptr)
		if err != nil {
			t.Errorf("Eval(%q): %v", tc.ptr, err)
			continue
		}
		if tc.ptr == "" {
			if !jsonvalue.Equal(got, doc) {
				t.Errorf("Eval(\"\") should be the whole document")
			}
			continue
		}
		if got.String() != tc.want {
			t.Errorf("Eval(%q) = %s, want %s", tc.ptr, got, tc.want)
		}
	}
}

func TestEvalErrors(t *testing.T) {
	doc, _ := jsonvalue.ParseString(`{"a":[1,2],"b":{"c":null}}`)
	for _, ptr := range []string{"/x", "/a/2", "/a/01", "/a/-", "/a/x", "/b/c/d", "/a/0/0"} {
		if _, err := Eval(doc, ptr); !errors.Is(err, ErrNotFound) {
			t.Errorf("Eval(%q) error = %v, want ErrNotFound", ptr, err)
		}
	}
	if _, err := Eval(doc, "a"); !errors.Is(err, ErrSyntax) {
		t.Errorf("Eval(a) error = %v, want ErrSyntax", err)
	}
}

func TestParseEscape(t *testing.T) {
	toks, err := Parse("/a~1b/m~0n//~01")
	if err != nil || !reflect.DeepEqual(toks, []string{"a/b", "m~n", "", "~1"}) {
		t.Errorf("Parse = %q, %v", toks, err)
	}
	if got := Escape("a/b~c"); got != "a~1b~0c" {
		t.Errorf("Escape = %q", got)
	}
	if got := Unescape(Escape("~/~1")); got != "~/~1" {
		t.Errorf("Unescape(Escape(x)) = %q", got)
	}
}
