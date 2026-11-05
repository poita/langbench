package regex

import "testing"

func TestMatchTable(t *testing.T) {
	tests := []struct {
		pat, in string
		want    bool
	}{
		// literals and search semantics
		{"bar", "foobarbaz", true},
		{"bar", "foo", false},
		{"", "anything", true},
		{"", "", true},
		{"^abc$", "abc", true},
		{"^abc$", "abcd", false},
		{"^a$", "a\n", false},
		{"^a", "ba", false},
		{"a$", "ab", false},
		{"^$", "", true},
		// alternation and groups
		{"^(a|b)c$", "bc", true},
		{"^(?:a|bc)d$", "bcd", true},
		{"^(a|ab)(c|bcd)$", "abcd", true},
		{"a|", "zzz", true},
		{"^(|a)$", "a", true},
		// quantifiers
		{"^a*$", "", true},
		{"^a+$", "", false},
		{"^a?b$", "b", true},
		{"^a{3}$", "aaa", true},
		{"^a{3}$", "aa", false},
		{"^a{2,}$", "aaaaa", true},
		{"^a{2,3}$", "aaaa", false},
		{"^a{2,3}$", "aa", true},
		{"^a{,3}$", "a{,3}", true},
		{"^a{x}$", "a{x}", true},
		{"a{1", "a{1", true},
		{"^a+?b$", "aab", true},
		{"^(a*)*$", "aaaa", true},
		{"^(a*)*b$", "aaaac", false},
		{"^(a+)+$", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab", false},
		{"^(x+x+)+y$", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", false},
		// dot
		{"^.$", "x", true},
		{"^.$", "\n", false},
		{"^.$", "\r", false},
		{"^.$", "\u2028", false},
		{"^.$", "\u2029", false},
		{"^.$", "\u2029", false},
		{"^.$", "💩", true},
		{"^.$", "é", true},
		{"^..$", "💩", false},
		// classes
		{"^[abc]+$", "abcabc", true},
		{"^[^abc]+$", "xyz", true},
		{"^[^abc]+$", "xay", false},
		{"^[a-c]$", "b", true},
		{"^[a-c]$", "d", false},
		{"^[a-]$", "-", true},
		{"^[-a]$", "-", true},
		{`^[a\-z]$`, "-", true},
		{`^[a\-z]$`, "b", false},
		{"^[]a]$", "a", false},
		{"[]", "a", false},
		{"[^]", "a", true},
		{`^[\d.]+$`, "1.5", true},
		{`^[\w-]+$`, "a-b_c", true},
		{`^[\s\S]$`, "\n", true},
		{`^[^\d]$`, "5", false},
		{`^[\D]$`, "x", true},
		{`^[\b]$`, "\b", true},
		{`^[à-ÿ]$`, "é", true},
		{`^[a-\d]$`, "-", true},
		{"^[😀-😎]$", "😁", true},
		{`^[😀-😎]$`, "😁", true},
		// escapes
		{`^\d+$`, "0123", true},
		{`^\d+$`, "01a", false},
		{`^\D+$`, "abc", true},
		{`^\w+$`, "ab_9", true},
		{`^\w+$`, "é", false},
		{`^\W$`, "é", true},
		{`^\s$`, "\u00a0", true},
		{`^\s$`, "\ufeff", true},
		{`^\s$`, "\u3000", true},
		{`^\s$`, "x", false},
		{`^\S+$`, "abc", true},
		{`^\n\r\t\f\v\0$`, "\n\r\t\f\v\x00", true},
		{`^\x41B$`, "AB", true},
		{`^💩$`, "💩", true},
		{`^\cJ$`, "\n", true},
		{`^\cj$`, "\n", true},
		{`^\.\*\\\[$`, `.*\[`, true},
		{`^\/\-$`, "/-", true},
		{`^a\.b$`, "axb", false},
		{`^\x4$`, "x4", true},
		// word boundaries
		{`\bcat\b`, "a cat sat", true},
		{`\bcat\b`, "concat", false},
		{`\bcat\b`, "écat ", true},
		{`\Bcat`, "concat", true},
		{`\Bcat`, "cat", false},
		{`^\b$`, "", false},
		{`^\B$`, "", true},
		// unicode
		{"^é$", "é", true},
		{"^日本$", "日本", true},
		{"^.{2}$", "日本", true},
		{"^.{1}$", "💩", true},
		// literal braces and brackets
		{"^}$", "}", true},
		{"^]$", "]", true},
		{"^{$", "{", true},
		{"^a{1,2}{$", "a{", true},
		// counted repetition of groups
		{"^(ab){2}$", "abab", true},
		{"^(ab){2}$", "ab", false},
		{"^(a|b){2,3}c$", "abc", true},
		// typical schema patterns
		{`^[a-z]+@[a-z]+\.com$`, "bob@example.com", true},
		{`^\d{3}-\d{4}$`, "555-1234", true},
		{`^\d{3}-\d{4}$`, "5555-1234", false},
		{`^(\([0-9]{3}\))?[0-9]{3}-[0-9]{4}$`, "(555)555-1234", true},
		{`^[^#]*#?$`, "http://x#", true},
		{`^[a-zA-Z_$][a-zA-Z0-9_$]*$`, "$a1", true},
	}
	for _, tc := range tests {
		re, err := Compile(tc.pat)
		if err != nil {
			t.Errorf("Compile(%q): %v", tc.pat, err)
			continue
		}
		if got := re.MatchString(tc.in); got != tc.want {
			t.Errorf("Compile(%q).MatchString(%q) = %v, want %v", tc.pat, tc.in, got, tc.want)
		}
	}
}

func TestSyntaxErrors(t *testing.T) {
	for _, pat := range []string{"(", "(a", "a)", "[a", "*a", "+", "?", "a**", "(?=a)", "(?<n>a)", "[b-a]", "a{3,2}", `\`, "a{99999999}"} {
		if _, err := Compile(pat); err == nil {
			t.Errorf("Compile(%q) succeeded, want error", pat)
		} else if _, ok := err.(*SyntaxError); !ok {
			t.Errorf("Compile(%q) error type %T", pat, err)
		}
	}
}

func TestMatchesAtEveryStart(t *testing.T) {
	re := MustCompile(`b+c`)
	if !re.MatchString("aaabbbc") || re.MatchString("aaabbb") {
		t.Error("unanchored search broken")
	}
	if re.String() != `b+c` {
		t.Error("String()")
	}
}

func TestLongSubjectIsLinear(t *testing.T) {
	subject := make([]byte, 50000)
	for i := range subject {
		subject[i] = 'a'
	}
	if MustCompile(`(a|aa)+$`).MatchString(string(subject) + "b") {
		t.Error("should not match")
	}
	if !MustCompile(`^(a*)*$`).MatchString(string(subject)) {
		t.Error("should match")
	}
}

func TestMustCompilePanics(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Error("MustCompile did not panic")
		}
	}()
	MustCompile("(")
}

func TestConcurrentUse(t *testing.T) {
	re := MustCompile(`^(ab|cd)+$`)
	done := make(chan bool)
	for i := 0; i < 8; i++ {
		go func() {
			ok := true
			for j := 0; j < 200; j++ {
				ok = ok && re.MatchString("abcdab") && !re.MatchString("abc")
			}
			done <- ok
		}()
	}
	for i := 0; i < 8; i++ {
		if !<-done {
			t.Error("concurrent mismatch")
		}
	}
}
