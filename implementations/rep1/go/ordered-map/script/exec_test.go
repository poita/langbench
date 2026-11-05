package script

import (
	"fmt"
	"strings"
	"testing"
)

func run(t *testing.T, in, want string) {
	t.Helper()
	if got := string(Execute([]byte(in))); got != want {
		t.Errorf("input:\n%s\ngot:\n%s\nwant:\n%s", in, got, want)
	}
}

func TestExample1(t *testing.T) {
	run(t, "12\nsize\nmin\ninsert 5 five\ninsert 5 FIVE\nget 5\ninsert 2 two\ninsert 9 nine\nmin\nmax\nrange 2 9\ndelete 5\nrange 3 8",
		"0\nempty\nok\nupdated\nFIVE\nok\nok\n2\n9\n2 5 9\nok\nempty\n")
}

func TestExample2(t *testing.T) {
	run(t, "14\ninsert 10 a\ninsert 20 b\ninsert 30 c\nfloor 25\nceil 25\nfloor 10\nceil 10\nsucc 10\npred 10\nsucc 30\nrank 20\nrank 21\nselect 2\nselect 3\n",
		"ok\nok\nok\n20\n30\n10\n10\n20\nmissing\nmissing\n1\n2\n30\nmissing\n")
}

func TestExtremeKeys(t *testing.T) {
	run(t, "9\ninsert -9223372036854775808 lo\ninsert 9223372036854775807 hi\ninsert 0 zero\nsucc 9223372036854775807\npred -9223372036854775808\nfloor -9223372036854775807\nceil 1\nrange -9223372036854775808 9223372036854775807\ndelete 0\n",
		"ok\nok\nok\nmissing\nmissing\n-9223372036854775808\n9223372036854775807\n-9223372036854775808 0 9223372036854775807\nok\n")
}

func TestEmptyAndZero(t *testing.T) {
	run(t, "0\n", "")
	run(t, "", "")
	run(t, "6\nmax\nrank 3\nselect 0\nselect 1000000000\nrange 1 0\nget 1\n",
		"empty\n0\nmissing\nmissing\nempty\nmissing\n")
}

func TestValuesAreOpaque(t *testing.T) {
	run(t, "4\ninsert 1 missing\nget 1\ninsert 2 \"'`\\<>|{}#\nget 2\n",
		"ok\nmissing\nok\n\"'`\\<>|{}#\n")
}

func TestCRLFTolerated(t *testing.T) {
	run(t, "2\r\ninsert 1 a\r\nget 1\r\n", "ok\na\n")
}

func TestLargeRangeLine(t *testing.T) {
	const n = 5000
	var b strings.Builder
	fmt.Fprintf(&b, "%d\n", n+1)
	for i := n; i > 0; i-- { // descending insert exercises rotations
		fmt.Fprintf(&b, "insert %d v\n", i)
	}
	b.WriteString("range 1 5000\n")
	out := string(Execute([]byte(b.String())))
	line := out[strings.LastIndex(strings.TrimSuffix(out, "\n"), "\n")+1:]
	fields := strings.Fields(line)
	if len(fields) != n || fields[0] != "1" || fields[n-1] != "5000" {
		t.Errorf("bad range line: %d fields", len(fields))
	}
}

func TestParseInt(t *testing.T) {
	cases := map[string]int64{
		"0": 0, "-1": -1, "123": 123,
		"9223372036854775807":  9223372036854775807,
		"-9223372036854775808": -9223372036854775808,
	}
	for s, want := range cases {
		if got := parseInt([]byte(s)); got != want {
			t.Errorf("parseInt(%q) = %d, want %d", s, got, want)
		}
	}
}
