package scan

import "testing"

func TestDecodeEntities(t *testing.T) {
	tests := []struct{ in, want string }{
		{"plain", "plain"},
		{"&amp;&lt;&gt;&quot;", "&<>\""},
		{"&#65;&#x42;&#X43;", "ABC"},
		{"&#0;", "�"},
		{"&#xD800;", "�"},
		{"&#1114112;", "�"},
		{"&#12345678;", "&#12345678;"},
		{"&#;&#x;&foo;&amp", "&#;&#x;&foo;&amp"},
		{"&AMP;", "&AMP;"},
	}
	for _, tc := range tests {
		if got := DecodeEntities(tc.in); got != tc.want {
			t.Errorf("DecodeEntities(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestUnescape(t *testing.T) {
	tests := []struct{ in, want string }{
		{`a\*b`, "a*b"},
		{`\\*`, `\*`},
		{`a\b`, `a\b`},
		{`end\`, `end\`},
	}
	for _, tc := range tests {
		if got := Unescape(tc.in); got != tc.want {
			t.Errorf("Unescape(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestClasses(t *testing.T) {
	for _, c := range []byte(" \t\n\v\f\r") {
		if !IsSpace(c) {
			t.Errorf("IsSpace(%q) = false", c)
		}
	}
	if IsSpace('a') || !IsPunct('_') || IsPunct('a') || !IsAlnum('7') || IsAlnum('-') {
		t.Error("character class mismatch")
	}
	if got := TrimSpace(" \t x y \n"); got != "x y" {
		t.Errorf("TrimSpace = %q", got)
	}
}
