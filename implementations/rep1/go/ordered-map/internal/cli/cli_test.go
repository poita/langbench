package cli

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

func TestExamples(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"empty", "0\n", ""},
		{"example1", "12\nsize\nmin\ninsert 5 five\ninsert 5 FIVE\nget 5\ninsert 2 two\ninsert 9 nine\nmin\nmax\nrange 2 9\ndelete 5\nrange 3 8",
			"0\nempty\nok\nupdated\nFIVE\nok\nok\n2\n9\n2 5 9\nok\nempty\n"},
		{"example2", "14\ninsert 10 a\ninsert 20 b\ninsert 30 c\nfloor 25\nceil 25\nfloor 10\nceil 10\nsucc 10\npred 10\nsucc 30\nrank 20\nrank 21\nselect 2\nselect 3\n",
			"ok\nok\nok\n20\n30\n10\n10\n20\nmissing\nmissing\n1\n2\n30\nmissing\n"},
		{"extremes", "9\ninsert -9223372036854775808 lo\ninsert 9223372036854775807 hi\ninsert 0 zero\nsucc 9223372036854775807\npred -9223372036854775808\nfloor -9223372036854775807\nceil 1\nrange -9223372036854775808 9223372036854775807\ndelete 0\n",
			"ok\nok\nok\nmissing\nmissing\n-9223372036854775808\n9223372036854775807\n-9223372036854775808 0 9223372036854775807\nok\n"},
		{"weird values", "3\ninsert 1 missing\nget 1\nget 2\n", "ok\nmissing\nmissing\n"},
		{"punctuation values", "2\ninsert 2 \"'`\\<>|{}#\nget 2\n", "ok\n\"'`\\<>|{}#\n"},
		{"empty-map", "5\nrank 3\nselect 0\nselect 1000000000\nrange 1 0\nmax\n", "0\nmissing\nmissing\nempty\nempty\n"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := run(t, tt.in); got != tt.want {
				t.Errorf("got %q want %q", got, tt.want)
			}
		})
	}
}

func TestUnknownCommand(t *testing.T) {
	var out bytes.Buffer
	if err := Run(strings.NewReader("1\nbogus\n"), &out); err == nil {
		t.Fatal("expected error")
	}
}
