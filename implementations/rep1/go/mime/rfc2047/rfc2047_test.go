package rfc2047

import "testing"

func TestDecodeUnstructured(t *testing.T) {
	cases := []struct{ in, want string }{
		{"=?utf-8?Q?caf=C3=A9?=", "café"},
		{"=?utf-8?Q?a?=   =?utf-8?Q?b?=", "ab"},
		{"x =?utf-8?Q?a?= y", "x a y"},
		{"=?utf-8?Q?a?=b", "ab"},
		{"=?iso-8859-1?Q?caf=E9?=", "café"},
		{"=?windows-1252?Q?smart=92quote?=", "smart’quote"},
		{"=?utf-8?B?SsO2cmc=?=", "Jörg"},
		{"=?utf-8*en?Q?hi?=", "hi"},
		{"=?utf-8?X?hi?=", "=?utf-8?X?hi?="},
		{"  plain    spaced   text  ", "plain    spaced   text"},
		{"=?utf-8?Q?a?= \t =?utf-8?Q?b?= \t c", "ab \t c"},
		{"=?utf-8?Q?a_b?=", "a b"},
		{"=?utf-8?Q?a=ZZb?=", "a=ZZb"},
		{"=?utf-8?Q?a b?=", "=?utf-8?Q?a b?="},
		{"=? ?Q?x?=", "=? ?Q?x?="},
		{"=??Q?x?=", "=??Q?x?="},
		{"=?*en?Q?x?=", "x"},
		{"ab=?utf-8?Q?c?=", "abc"},
		{"=?utf-8?Q??=", ""},
	}
	for _, c := range cases {
		if got := DecodeUnstructured(c.in); got != c.want {
			t.Errorf("DecodeUnstructured(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestDecodeDisplay(t *testing.T) {
	cases := []struct{ in, want string }{
		{"John Q. Public ", "John Q. Public"},
		{`"Doe, John" `, "Doe, John"},
		{"=?utf-8?B?SsO2cmc=?= ", "Jörg"},
		{"John (the third) Public ", "John   Public"},
		{`"=?utf-8?Q?x?="`, "=?utf-8?Q?x?="},
		{`"a\"b"`, `a"b`},
		{"(c)", ""},
	}
	for _, c := range cases {
		if got := DecodeDisplay(c.in); got != c.want {
			t.Errorf("DecodeDisplay(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestMatchEnd(t *testing.T) {
	text, end, ok := Match("x=?utf-8?Q?a?=y", 1)
	if !ok || text != "a" || end != 14 {
		t.Errorf("Match = %q %d %v", text, end, ok)
	}
	if _, _, ok := Match("=?utf-8?Q?a?", 0); ok {
		t.Error("unterminated word matched")
	}
}
