package datalog_test

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"example.com/datalog"
)

func runString(t *testing.T, src string) string {
	t.Helper()
	res, err := datalog.Run(src)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	var buf bytes.Buffer
	if err := datalog.WriteResults(&buf, res); err != nil {
		t.Fatal(err)
	}
	return buf.String()
}

// TestGolden runs every testdata/*.in and compares with the .out file. A
// program that fails the safety or stratification check must expect "error".
func TestGolden(t *testing.T) {
	files, _ := filepath.Glob("testdata/*.in")
	if len(files) == 0 {
		t.Fatal("no golden files")
	}
	for _, in := range files {
		name := strings.TrimSuffix(filepath.Base(in), ".in")
		t.Run(name, func(t *testing.T) {
			src, err := os.ReadFile(in)
			if err != nil {
				t.Fatal(err)
			}
			want, err := os.ReadFile(strings.TrimSuffix(in, ".in") + ".out")
			if err != nil {
				t.Fatal(err)
			}
			var got string
			res, err := datalog.Run(string(src))
			var ue *datalog.UnsafeError
			var ne *datalog.NotStratifiableError
			if errors.As(err, &ue) || errors.As(err, &ne) {
				got = "error\n"
			} else if err != nil {
				t.Fatal(err)
			} else {
				var buf bytes.Buffer
				datalog.WriteResults(&buf, res)
				got = buf.String()
			}
			if got != string(want) {
				t.Errorf("got:\n%s\nwant:\n%s", got, want)
			}
		})
	}
}

func TestErrorTypes(t *testing.T) {
	_, err := datalog.Run("p(X) :- q(Y).")
	var ue *datalog.UnsafeError
	if !errors.As(err, &ue) {
		t.Errorf("err = %v", err)
	}
	_, err = datalog.Run("p(X) :- q(X), not p(X).")
	var ne *datalog.NotStratifiableError
	if !errors.As(err, &ne) {
		t.Errorf("err = %v", err)
	}
	_, err = datalog.Run("p(X")
	var se *datalog.SyntaxError
	if !errors.As(err, &se) {
		t.Errorf("err = %v", err)
	}
	// Safety is checked first, and errors win over earlier queries.
	_, err = datalog.Run("a(X) :- b(X), not a(X). c(X) :- d(Y).")
	if !errors.As(err, &ue) {
		t.Errorf("safety must be reported first: %v", err)
	}
}

func TestModelQuery(t *testing.T) {
	prog, err := datalog.Parse(`
		parent(tom, bob). parent(tom, liz). parent(bob, ann).
		anc(X, Y) :- parent(X, Y).
		anc(X, Z) :- parent(X, Y), anc(Y, Z).`)
	if err != nil {
		t.Fatal(err)
	}
	m, err := datalog.Evaluate(prog)
	if err != nil {
		t.Fatal(err)
	}
	q, _ := datalog.Parse("?- anc(tom, X).")
	got := m.Query(q.Queries[0])
	if len(got) != 3 || got[0].Format("anc") != "anc(tom, ann)" || got[2].Format("anc") != "anc(tom, liz)" {
		t.Errorf("got %v", got)
	}
}

func TestQueryOrderIgnoresPosition(t *testing.T) {
	got := runString(t, "?- p(X).\np(2). p(1).\n?- p(1).\n")
	want := "p(1)\np(2)\n-- 2\np(1)\n-- 1\n"
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestRepeatedQueryVariable(t *testing.T) {
	got := runString(t, "e(1,1). e(1,2). e(2,2).\n?- e(X, X).\n?- e(_, _).\n")
	want := "e(1, 1)\ne(2, 2)\n-- 2\ne(1, 1)\ne(1, 2)\ne(2, 2)\n-- 3\n"
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func ExampleRun() {
	res, err := datalog.Run(`
		edge(a, b). edge(b, c).
		path(X, Y) :- edge(X, Y).
		path(X, Z) :- edge(X, Y), path(Y, Z).
		?- path(a, X).`)
	if err != nil {
		panic(err)
	}
	datalog.WriteResults(os.Stdout, res)
	// Output:
	// path(a, b)
	// path(a, c)
	// -- 2
}
