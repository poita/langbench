package main

import (
	"strings"
	"testing"
)

func TestRun(t *testing.T) {
	var out strings.Builder
	in := strings.NewReader("CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (1),(2); SELECT a FROM t; SELECT * FROM x;")
	if err := run(in, &out); err != nil {
		t.Fatal(err)
	}
	if want := "1\n2\n-- 2 rows\nerror\n"; out.String() != want {
		t.Errorf("got %q, want %q", out.String(), want)
	}
}
