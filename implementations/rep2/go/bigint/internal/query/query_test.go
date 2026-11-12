package query

import (
	"bytes"
	"strings"
	"testing"
)

func run(t *testing.T, in string) string {
	t.Helper()
	var out bytes.Buffer
	if err := Run(strings.NewReader(in), &out); err != nil {
		t.Fatal(err)
	}
	return out.String()
}

func TestRun(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"empty", "", ""},
		{"no trailing newline", "12 + 30", "42\n"},
		{"trailing newline", "12 + 30\n", "42\n"},
		{"example 1", "12 + 30\n5 - 7\n-7 / 2\n-7 % 2\n", "42\n-2\n-3\n-1\n"},
		{"example 2", "-0 + 0\n007 cmp 7\n-5 * 0\n99999999999999999999 + 1\n2 ^ 10\n0 ^ 0\n",
			"0\n0\n0\n100000000000000000000\n1024\n1\n"},
		{"errors", "1 / 0\n0 % 0\n2 ^ -1\n5 / -0\n5 ^ -0\n-0 ^ -00\n", "error\nerror\nerror\nerror\n1\n1\n"},
		{"cmp", "-3 cmp -2\n2 cmp -3\n5 cmp 5\n", "-1\n1\n0\n"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := run(t, tc.in); got != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestLongLine(t *testing.T) {
	n := strings.Repeat("9", 50100)
	got := run(t, n+" + 1\n")
	if want := "1" + strings.Repeat("0", 50100) + "\n"; got != want {
		t.Errorf("long add wrong (len %d)", len(got))
	}
}

func TestMalformed(t *testing.T) {
	for _, in := range []string{"1 +", "1 ? 2", "x + 1", "1 + 2 3"} {
		if _, err := Eval(in); err == nil {
			t.Errorf("Eval(%q): expected error", in)
		}
	}
}
