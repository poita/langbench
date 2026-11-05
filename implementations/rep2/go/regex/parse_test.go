package regexvm

import "testing"

func TestParseErrors(t *testing.T) {
	bad := []string{"(", ")", "a)", "*a", "a**", "a{2}{3}", "^*", "$+", "[a", "[]", "a{2", "a{3,1}", `\`, `\d{`, `\b`, "(*)", "|*", "]", "}"}
	for _, p := range bad {
		if _, err := Compile(p); err == nil {
			t.Errorf("Compile(%q): expected error", p)
		} else if _, ok := err.(*SyntaxError); !ok {
			t.Errorf("Compile(%q): error %T, want *SyntaxError", p, err)
		}
	}
}

func TestParseValid(t *testing.T) {
	good := []string{"", "a|", "(|b)", "||", "()", "a{0}", "a{0,0}", "(a){2,}", `\.\\\(\ `, "[-a]", "[a-]", `[\-a]`, "[^^]", `[\]\[]`, `[\d-]`, "[a-c]x"}
	for _, p := range good {
		if _, err := Compile(p); err != nil {
			t.Errorf("Compile(%q): %v", p, err)
		}
	}
}

func TestGroupCount(t *testing.T) {
	cases := map[string]int{"": 0, "a": 0, "(a)(b)": 2, "((a)b)(c)": 3, "(a){0}": 1, "()": 1}
	for p, want := range cases {
		if got := MustCompile(p).NumGroups(); got != want {
			t.Errorf("%q: NumGroups = %d, want %d", p, got, want)
		}
	}
}

func TestTooLarge(t *testing.T) {
	if _, err := Compile("((((a{100}){100}){100}){100})"); err == nil {
		t.Error("expected size error")
	}
}
