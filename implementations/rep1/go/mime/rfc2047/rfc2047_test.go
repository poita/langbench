package rfc2047

import "testing"

func TestDecodeUnstructured(t *testing.T) {
	tests := []struct{ in, want string }{
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
		{"=?utf-8?Q?a=4?=", "a=4"},
		{"=??Q?a?=", "=??Q?a?="},
		{"=?utf-8?q?a?=", "a"},
		{"=?utf-8?Q?a b?=", "=?utf-8?Q?a b?="},
		{"=?utf-8?Q??=", ""},
		{"=?=?utf-8?Q?a?=", "=?a"},
		{"", ""},
	}
	for _, tc := range tests {
		if got := DecodeUnstructured(tc.in); got != tc.want {
			t.Errorf("DecodeUnstructured(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestDecodeDisplay(t *testing.T) {
	tests := []struct{ in, want string }{
		{"John Q. Public ", "John Q. Public"},
		{`"Doe, John" `, "Doe, John"},
		{"=?utf-8?B?SsO2cmc=?= ", "Jörg"},
		{"John (the third) Public ", "John   Public"},
		{`"=?utf-8?Q?x?=" `, "=?utf-8?Q?x?="},
		{"foo (c (nested)) ", "foo"},
		{`a\ b`, `a\ b`},
	}
	for _, tc := range tests {
		if got := DecodeDisplay(tc.in); got != tc.want {
			t.Errorf("DecodeDisplay(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}
