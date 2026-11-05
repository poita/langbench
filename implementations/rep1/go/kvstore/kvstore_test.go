package kvstore

import (
	"bytes"
	"strings"
	"testing"
)

func TestWorkedExample(t *testing.T) {
	script := "put \"b\" 2\nput \"a\" {name:\"ada\",age:36}\nget \"a\"\nscan\nstat\n"
	want := `[1] ok put created
[2] ok put created
[3] ok get value
  {"age":36,"name":"ada"}
[4] ok scan 2
  "a" = {"age":36,"name":"ada"}
  "b" = 2
[5] ok stat
  pages 2
  free 0
  freehead 0
  docs 2
  root 2
  height 1
  commits 2
  indexes 0
  wal 4272
`
	results, mainOut, walOut := RunScript([]byte(script), nil, nil)
	if string(results) != want {
		t.Fatalf("results:\n%s\nwant:\n%s", results, want)
	}
	if len(mainOut) != 1024 || len(walOut) != 4272 {
		t.Fatalf("file sizes main=%d wal=%d", len(mainOut), len(walOut))
	}
}

func TestSplitLines(t *testing.T) {
	tests := []struct {
		in   string
		want int
	}{{"", 0}, {"a", 1}, {"a\n", 1}, {"a\nb", 2}, {"a\nb\n", 2}, {"a\nb\n\n", 3}, {"\n", 1}}
	for _, tc := range tests {
		if got := len(SplitLines([]byte(tc.in))); got != tc.want {
			t.Errorf("SplitLines(%q) = %d lines, want %d", tc.in, got, tc.want)
		}
	}
	results, _, _ := RunScript(nil, nil, nil)
	if len(results) != 0 {
		t.Fatal("empty script must give empty results")
	}
}

func TestErrorsLeaveNoTrace(t *testing.T) {
	s := Open(nil, nil)
	for _, c := range []struct{ line, want string }{
		{`put "a" 1`, "[1] ok put created\n"},
		{`get "zz"`, "[2] error not-found\n"},
		{`commit`, "[3] error no-txn\n"},
		{`begin`, "[4] ok begin\n"},
		{`begin`, "[5] error txn-active\n"},
		{`unset "a" x`, "[6] error not-object\n"},
		{`update "a" x 1`, "[7] error not-object\n"},
		{``, "[8] error syntax\n"},
		{`rollback`, "[9] ok rollback\n"},
		{`stat`, "[10] ok stat\n  pages 2\n  free 0\n  freehead 0\n  docs 1\n  root 2\n  height 1\n  commits 1\n  indexes 0\n  wal 2152\n"},
	} {
		if got := s.Exec(c.line); got != c.want {
			t.Errorf("%s: got %q, want %q", c.line, got, c.want)
		}
	}
}

func TestTransactionRolledBackAtClose(t *testing.T) {
	s := Open(nil, nil)
	s.Exec("begin")
	s.Exec(`put "a" 1`)
	s.Close()
	m, w := s.Files()
	if len(m) != 1024 || len(w) != 32 {
		t.Fatalf("open transaction leaked: main %d wal %d", len(m), len(w))
	}
}

func TestPersistenceThroughFiles(t *testing.T) {
	s := Open(nil, nil)
	s.Exec(`put "k" {a:[1,2,{b:null}]}`)
	s.Exec(`create index a`)
	s.Exec(`checkpoint`)
	s.Exec(`put "j" "tail"`)
	m, w := s.Files()

	s2 := Open(m, w)
	if got := s2.Exec(`get "k"`); got != "[1] ok get value\n  {\"a\":[1,2,{\"b\":null}]}\n" {
		t.Fatalf("got %q", got)
	}
	if got := s2.Exec(`indexes`); !strings.HasPrefix(got, "[2] ok indexes 1\n  0 a root ") {
		t.Fatalf("got %q", got)
	}
	if got := s2.Exec(`scan keys reverse`); got != "[3] ok scan 2\n  \"k\"\n  \"j\"\n" {
		t.Fatalf("got %q", got)
	}
	// Opening must not modify the inputs.
	m2, w2 := append([]byte(nil), m...), append([]byte(nil), w...)
	Open(m, w)
	if !bytes.Equal(m, m2) || !bytes.Equal(w, w2) {
		t.Fatal("Open modified its inputs")
	}
}
