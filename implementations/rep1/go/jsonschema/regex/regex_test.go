package regex

import (
	"strings"
	"testing"
	"time"
)

func TestMatch(t *testing.T) {
	tests := []struct {
		pat, s string
		want   bool
	}{
		// Search, not full match.
		{"bar", "foobarbaz", true},
		{"bar", "foobaz", false},
		{"", "", true},
		{"", "abc", true},
		// Anchors: ^ and $ are string anchors only.
		{"^a$", "a", true},
		{"^a$", "a\n", false},
		{"^a", "ba", false},
		{"a$", "ab", false},
		{"^$", "", true},
		{"^$", "\n", false},
		{"^(a|b)$", "b", true},
		{"a|^b", "cb", false},
		{"a|^b", "bc", true},
		// Alternation, groups.
		{"^(?:ab|cd)+$", "abcdab", true},
		{"^(ab|cd)+$", "abcdabx", false},
		{"^(a|ab)(c|bcd)(d*)$", "abcd", true},
		// Quantifiers.
		{"^a*$", "", true},
		{"^a+$", "", false},
		{"^a?$", "aa", false},
		{"^a{2}$", "aa", true},
		{"^a{2}$", "aaa", false},
		{"^a{2,}$", "aaaa", true},
		{"^a{2,}$", "a", false},
		{"^a{2,3}$", "aaaa", false},
		{"^a{2,3}$", "aaa", true},
		{"^a{0}$", "", true},
		{"^a{0,2}b$", "aab", true},
		{"^a*?b$", "aab", true},
		{"^(?:ab){2,3}$", "ababab", true},
		{"^(?:ab){2,3}$", "ab", false},
		// A '{' that is not a quantifier is literal.
		{"a{", "a{", true},
		{"a{x}", "a{x}", true},
		{"a{1,x}", "a{1,x}", true},
		{"{", "{", true},
		{"a{1", "a{1", true},
		{"}", "}", true},
		{"]", "]", true},
		// Dot.
		{"^.$", "é", true},
		{"^.$", "\U0001F4A9", true},
		{"^.$", "\n", false},
		{"^.$", "\r", false},
		{"^.$", "\u2028", false},
		{"^.$", "\u2029", false},
		{"^.$", "\u2029", false},
		{"^.$", "\u0085", true},
		{"^..$", "\U0001F4A9", false},
		// Word boundaries are ASCII-only.
		{`\bcat\b`, "a cat sat", true},
		{`\bcat\b`, "concat", false},
		{`\bcat\b`, "écat ", true},
		{`\Bcat`, "concat", true},
		{`\Bcat`, "cat", false},
		{`\b`, "", false},
		{`\B`, "", true},
		{`^\b`, "a", true},
		{`a\b$`, "a", true},
		// Classes.
		{"^[abc]+$", "abcabc", true},
		{"^[a-c]+$", "abd", false},
		{"^[^a-c]+$", "xyz", true},
		{"^[^a-c]+$", "xaz", false},
		{"^[a-]+$", "a-a", true},
		{"^[-a]+$", "a-a", true},
		{`^[\-a]+$`, "a-", true},
		{`^[a\]]+$`, "a]", true},
		{`^[\d-x]+$`, "1-x", true},
		{`^[\w.]+$`, "a.b_1", true},
		{`^[\w.]+$`, "a b", false},
		{`^[\s]+$`, " \t\n \u3000\ufeff", true},
		{`^[\S]+$`, "ab", true},
		{`^[\D]+$`, "ab1", false},
		{`^[\W]+$`, "!? ", true},
		{`[\b]`, "\b", true},
		{`[\b]`, "b", false},
		{"[]", "a", false},
		{"[^]", "a", true},
		{"^[à-ÿ]+$", "éà", true},
		{"^[\U0001F300-\U0001F6FF]$", "\U0001F4A9", true},
		{"^[^a]$", "\U0001F4A9", true},
		// Escapes.
		{`^\d+$`, "0123", true},
		{`^\d+$`, "١٢٣", false}, // only ASCII digits
		{`^\D$`, "a", true},
		{`^\w+$`, "aZ_9", true},
		{`^\w+$`, "é", false},
		{`^\W$`, "é", true},
		{`^\s$`, " ", true},
		{`^\s$`, "\u200b", false},
		{`^\S$`, "a", true},
		{`^\n\r\t\f\v\0$`, "\n\r\t\f\v\x00", true},
		{`^\x41B$`, "AB", true},
		{`^💩$`, "\U0001F4A9", true},
		{`^é$`, "é", true},
		{`^\cJ$`, "\n", true},
		{`^\ca$`, "\x01", true},
		{`^\.\\\*\[\/\-\$$`, `.\*[/-$`, true},
		{`^\a$`, "a", true},
		// Pathological patterns stay fast and correct.
		{"^(a*)*$", "aaaa", true},
		{"^(a*)*b$", "aaaa", false},
		{"^(?:a?){3}a{3}$", "aaa", true},
		{"(?:)*", "x", true},
		{"^(?:a|)+$", "aaa", true},
	}
	for _, tc := range tests {
		re, err := Compile(tc.pat)
		if err != nil {
			t.Errorf("Compile(%q): %v", tc.pat, err)
			continue
		}
		if got := re.MatchString(tc.s); got != tc.want {
			t.Errorf("%q.MatchString(%q) = %v, want %v", tc.pat, tc.s, got, tc.want)
		}
	}
}

func TestSyntaxErrors(t *testing.T) {
	for _, p := range []string{"(", ")", "a)", "[a", "*", "+a", "?", "a**", `\`, "(?=a)", "(?!a)", "(?<n>a)", `(a)\1`, "[b-a]", "a{3,2}", "{2}"} {
		if _, err := Compile(p); err == nil {
			t.Errorf("Compile(%q) should fail", p)
		}
	}
}

func TestLiteralFastPath(t *testing.T) {
	re := MustCompile("abc")
	if !re.isLit {
		t.Error("abc should be recognised as a literal")
	}
	if re := MustCompile(`a\.b`); !re.isLit || !re.MatchString("xa.by") || re.MatchString("axb") {
		t.Error(`a\.b literal handling`)
	}
	if MustCompile("a|b").isLit {
		t.Error("a|b is not a literal")
	}
}

// Matching must be O(P*L): a classic exponential-backtracking input must
// finish instantly.
func TestNoExponentialBlowup(t *testing.T) {
	subject := strings.Repeat("a", 5000) + "!"
	for _, p := range []string{`^(a+)+$`, `^(a|aa)+$`, `^(a*)*$`, `(x+x+)+y`, `^(?:a{1,50}){1,50}$`} {
		re := MustCompile(p)
		start := time.Now()
		re.MatchString(subject)
		if d := time.Since(start); d > 5*time.Second {
			t.Errorf("%q took %v", p, d)
		}
	}
}

func TestCountedRepetitionLimit(t *testing.T) {
	if _, err := Compile(`(?:(?:a{1000}){1000}){1000}`); err == nil {
		t.Error("enormous expansion should be rejected")
	}
	re := MustCompile(`^a{100,200}$`)
	if !re.MatchString(strings.Repeat("a", 150)) || re.MatchString(strings.Repeat("a", 99)) || re.MatchString(strings.Repeat("a", 201)) {
		t.Error("a{100,200} wrong")
	}
}

func TestConcurrentUse(t *testing.T) {
	re := MustCompile(`^(?:ab)+c$`)
	done := make(chan bool)
	for i := 0; i < 8; i++ {
		go func() {
			ok := true
			for j := 0; j < 200; j++ {
				ok = ok && re.MatchString("ababababc") && !re.MatchString("ababab")
			}
			done <- ok
		}()
	}
	for i := 0; i < 8; i++ {
		if !<-done {
			t.Fatal("concurrent matching gave a wrong answer")
		}
	}
}

func TestCharsetNegate(t *testing.T) {
	cs := (&charset{r: []rune{'b', 'd', 'x', 'x'}}).normalize()
	neg := cs.negate()
	for r, want := range map[rune]bool{'a': true, 'b': false, 'c': false, 'd': false, 'e': true, 'x': false, 'y': true, maxRune: true, 0: true} {
		if neg.contains(r) != want {
			t.Errorf("negated contains(%q) = %v", r, !want)
		}
	}
}
