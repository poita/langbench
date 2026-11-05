package minisql

import "testing"

func TestLike(t *testing.T) {
	cases := []struct {
		s, p string
		want bool
	}{
		{"apple", "apple", true},
		{"APPLE", "apple", true},
		{"apple", "a%", true},
		{"apple", "%e", true},
		{"apple", "%pp%", true},
		{"apple", "a_ple", true},
		{"apple", "a_le", false},
		{"apple", "", false},
		{"", "", true},
		{"", "%", true},
		{"", "_", false},
		{"abc", "%%c", true},
		{"abcabc", "%abc", true},
		{"aXbXc", "a%b%c", true},
		{"abc", "a%d", false},
		{"É", "é", false},
		{"é", "_", true},
		{"éa", "_a", true},
		{"éa", "__", true},
		{"é", "__", false},
		{"éé", "%_", true},
		{"日本語", "日_語", true},
		{"日本語", "%本%", true},
		{"mississippi", "m%iss%pi", true},
		{"mississippi", "m%iss%pp", false},
	}
	for _, c := range cases {
		if got := like(c.s, c.p); got != c.want {
			t.Errorf("like(%q, %q) = %v, want %v", c.s, c.p, got, c.want)
		}
	}
}
