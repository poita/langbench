package jsoncanon

import (
	"strings"
	"testing"
)

func TestCanonicalize(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"empty object", `{}`, `{}`},
		{"empty array", ` [ ] `, `[]`},
		{"literals", `[true,false,null]`, `[true,false,null]`},
		{"whitespace", " \t\r\n{ \"a\" : [ 1 , 2 ] }\n", `{"a":[1,2]}`},
		{"worked example 1", `{ "b": [1, 2.50, 1E+3], "a": "héllo\/", "b": null }`, `{"a":"héllo/","b":null}`},
		{"worked example 2", `["😀", -0, 1e-007, 0.0, 1e-0, "tab\tquote\"nul\u0000 A\u0041"]`,
			`["😀",-0,1e-7,0.0,1e0,"tab\tquote\"nul\u0000 AA"]`},
		{"raw specials", `"\u007f\/\u2028\uD83D\uDE00"`, "\"\x7f/\u2028\U0001F600\""},
		{"utf16 key order", `{"\uE000":1,"😀":2,"\uFFFF":3,"Z":4}`, "{\"Z\":4,\"😀\":2,\"\uE000\":1,\"\uFFFF\":3}"},
		{"key order spec example", "{\"\uE000\":0,\"😀\":0,\"é\":0,\"aa\":0,\"a\\u0000\":0,\"a\":0,\"Z\":0,\"\":0}",
			"{\"\":0,\"Z\":0,\"a\":0,\"a\\u0000\":0,\"aa\":0,\"é\":0,\"😀\":0,\"\uE000\":0}"},
		{"duplicate last wins", `{"a":1,"b":2,"a":3,"\u0061":4}`, `{"a":4,"b":2}`},
		{"escaped dup key", `{"a":1,"\u0061":2}`, `{"a":2}`},
		{"control escapes", `"\b\f\n\r\t\u001F\u0000\u0001"`, `"\b\f\n\r\t\u001f\u0000\u0001"`},
		{"quote and backslash", `"\"\\"`, `"\"\\"`},
		{"big int", `123456789012345678901234567890`, `123456789012345678901234567890`},
		{"neg zero", `-0`, `-0`},
		{"frac kept", `[1.0,1.50,-0.0,0e0]`, `[1.0,1.50,-0.0,0e0]`},
		{"exp normalization", `[1E5,1e+05,1e-007,1e-0,1E+00,2.5E-000789,0e-0]`, `[1e5,1e5,1e-7,1e0,1e0,2.5e-789,0e0]`},
		{"long exp zeros", `1e0000000000000000000000000012`, `1e12`},
		{"top-level string", `"x"`, `"x"`},
		{"top-level number", ` 42 `, `42`},
		{"nested", `{"b":{"y":1,"x":[{"d":1,"c":2}]},"a":0}`, `{"a":0,"b":{"x":[{"c":2,"d":1}],"y":1}}`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := Canonicalize([]byte(tc.in))
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if string(got) != tc.want {
				t.Errorf("got  %q\nwant %q", got, tc.want)
			}
		})
	}
}

func TestInvalid(t *testing.T) {
	deep := func(n int, leaf string) string { return strings.Repeat("[", n) + leaf + strings.Repeat("]", n) }
	tests := []struct{ name, in string }{
		{"empty", ``},
		{"only whitespace", " \n\t "},
		{"BOM", "\xEF\xBB\xBF{}"},
		{"trailing comma array", `[1,]`},
		{"trailing comma object", `{"a":1,}`},
		{"leading comma", `[,1]`},
		{"missing comma", `[1 2]`},
		{"missing colon", `{"a" 1}`},
		{"non-string key", `{1:2}`},
		{"unquoted key", `{a:1}`},
		{"single quotes", `'a'`},
		{"comment", `[1]//x`},
		{"two values", `1 2`},
		{"trailing garbage", `{} x`},
		{"trailing NUL", "{}\x00"},
		{"form feed", "\f{}"},
		{"vertical tab", "\v1"},
		{"NBSP", "\u00a0 1"},
		{"U+2028", "1\u2028"},
		{"NEL", "1\u0085"},
		{"True", `True`},
		{"NaN", `NaN`},
		{"Infinity", `-Infinity`},
		{"nul", `nul`},
		{"nullx", `nullx`},
		{"leading zero", `01`},
		{"plus", `+1`},
		{"minus alone", `-`},
		{"dot trailing", `1.`},
		{"dot leading", `.5`},
		{"exp empty", `1e`},
		{"exp sign only", `1e+`},
		{"exp double sign", `1E+-5`},
		{"double exp", `1e5e5`},
		{"hex", `0x1`},
		{"space in number", `- 1`},
		{"arabic digit", "\u0662"},
		{"superscript", "1\u00b2"},
		{"fullwidth", "\uff11"},
		{"raw tab in string", "\"a\tb\""},
		{"raw newline in string", "\"a\nb\""},
		{"raw NUL in string", "\"a\x00b\""},
		{"unterminated string", `"abc`},
		{"backslash at end", `["\`},
		{"bad escape", `"\x"`},
		{"bad escape quote", `"\'"`},
		{"escape zero", `"\0"`},
		{"truncated u", `"\u12"`},
		{"non-hex u", `"\u12G4"`},
		{"fullwidth hex", "\"\\u１２３４\""},
		{"high surrogate alone", `"\uD800"`},
		{"high then other", `"\uD800\u0041"`},
		{"high then E000", `"\uD800\uE000"`},
		{"high then high", `"\uD800\uDBFF"`},
		{"high then raw", `"\uD800a"`},
		{"low alone", `"\uDC00"`},
		{"low then high", `"\uDC00\uD800"`},
		{"surrogate in key", `{"\uD800":1}`},
		{"discarded dup bad surrogate", `{"a":"\uD800","a":1}`},
		{"discarded dup bad array", `{"a":[1,],"a":1}`},
		{"discarded dup too deep", `{"a":` + deep(513, "") + `,"a":1}`},
		{"overlong", "\"\xC0\x80\""},
		{"overlong 3", "\"\xE0\x80\x80\""},
		{"surrogate utf8", "\"\xED\xA0\x80\""},
		{"above 10FFFF", "\"\xF4\x90\x80\x80\""},
		{"F5", "\"\xF5\x80\x80\x80\""},
		{"truncated utf8", "\"\xE2\x82\""},
		{"lone continuation", "\"\x80\""},
		{"bad utf8 after value", "1\xff"},
		{"depth 513", deep(513, "")},
		{"depth 513 object", deep(512, "{}")},
		{"unclosed", strings.Repeat("[", 100000)},
		{"unclosed object", `{"a":`},
		{"unterminated array", `[1,2`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := Canonicalize([]byte(tc.in))
			if err == nil {
				t.Fatalf("expected error, got %q", got)
			}
			if _, ok := err.(*SyntaxError); !ok {
				t.Errorf("error type %T, want *SyntaxError", err)
			}
		})
	}
}

func TestDepthLimit(t *testing.T) {
	in := strings.Repeat("[", MaxDepth) + strings.Repeat("]", MaxDepth)
	got, err := Canonicalize([]byte(in))
	if err != nil || string(got) != in {
		t.Fatalf("depth %d: got %q, %v", MaxDepth, got, err)
	}
	in = strings.Repeat(`{"a":`, MaxDepth-1) + `[]` + strings.Repeat("}", MaxDepth-1)
	if _, err := Canonicalize([]byte(in)); err != nil {
		t.Fatalf("mixed depth %d: %v", MaxDepth, err)
	}
}

func TestLargeAndManyKeys(t *testing.T) {
	var sb strings.Builder
	sb.WriteString("{")
	for i := 0; i < 5000; i++ {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(`"user:`)
		sb.WriteString(strings.Repeat("0", 8))
		sb.WriteString(string(rune('a' + i%26)))
		sb.WriteString(`":`)
		sb.WriteString("1")
	}
	sb.WriteString("}")
	got, err := Canonicalize([]byte(sb.String()))
	if err != nil {
		t.Fatal(err)
	}
	if n := strings.Count(string(got), ":"); n != 26+26 { // "user:" colon + value colon per key
		t.Errorf("expected 26 unique keys, got colon count %d", n)
	}
}

func TestLongNumbers(t *testing.T) {
	digits := strings.Repeat("9", 5000)
	in := "[" + digits + "." + digits + "e+" + "000" + digits + "]"
	want := "[" + digits + "." + digits + "e" + digits + "]"
	got, err := Canonicalize([]byte(in))
	if err != nil || string(got) != want {
		t.Fatalf("long number mismatch, err=%v", err)
	}
}
