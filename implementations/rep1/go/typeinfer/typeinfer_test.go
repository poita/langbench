package typeinfer_test

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/example/typeinfer"
	"github.com/example/typeinfer/syntax"
)

// TestGolden runs every testdata/golden/*.in through Run and compares the
// output with the matching .out file (ignoring trailing whitespace).
func TestGolden(t *testing.T) {
	files, err := filepath.Glob("testdata/golden/*.in")
	if err != nil || len(files) == 0 {
		t.Fatalf("no golden files: %v", err)
	}
	trim := func(s string) string {
		lines := strings.Split(strings.ReplaceAll(s, "\r\n", "\n"), "\n")
		for i, l := range lines {
			lines[i] = strings.TrimRight(l, " \t")
		}
		return strings.TrimRight(strings.Join(lines, "\n"), "\n")
	}
	for _, f := range files {
		name := strings.TrimSuffix(filepath.Base(f), ".in")
		t.Run(name, func(t *testing.T) {
			in, err := os.ReadFile(f)
			if err != nil {
				t.Fatal(err)
			}
			want, err := os.ReadFile(strings.TrimSuffix(f, ".in") + ".out")
			if err != nil {
				t.Fatal(err)
			}
			var out bytes.Buffer
			if err := typeinfer.Run(bytes.NewReader(in), &out); err != nil {
				t.Fatal(err)
			}
			if got := trim(out.String()); got != trim(string(want)) {
				t.Errorf("output mismatch\n got: %.300q\nwant: %.300q", got, trim(string(want)))
			}
		})
	}
}

func TestInfer(t *testing.T) {
	res, err := typeinfer.Infer("let id = fun x -> x;; id 1;; fun x -> x x;; y;; let z = true + 1;;")
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"id : 'a -> 'a", "- : int", "error: occurs", "error: unbound", "error: unify"}
	if len(res) != len(want) {
		t.Fatalf("got %d results", len(res))
	}
	for i, r := range res {
		if r.String() != want[i] {
			t.Errorf("result %d: got %q, want %q", i, r, want[i])
		}
	}
	if res[0].Name != "id" || res[0].Type != "'a -> 'a" || res[0].Err != nil {
		t.Errorf("unexpected result %+v", res[0])
	}
	if res[4].Name != "z" || res[4].Err == nil {
		t.Errorf("unexpected result %+v", res[4])
	}
}

func TestInferSyntaxError(t *testing.T) {
	res, err := typeinfer.Infer("1;; let = ;;")
	if _, ok := err.(*syntax.Error); !ok {
		t.Errorf("got err %v", err)
	}
	if len(res) != 1 || res[0].String() != "- : int" {
		t.Errorf("got %v", res)
	}
}

func TestRunEmpty(t *testing.T) {
	var out bytes.Buffer
	if err := typeinfer.Run(strings.NewReader(" \n"), &out); err != nil || out.Len() != 0 {
		t.Errorf("got %q, %v", out.String(), err)
	}
}

func TestDeepProgram(t *testing.T) {
	const n = 3000
	src := "(" + strings.Repeat("let x = 1 in ", n) + "x);;"
	res, err := typeinfer.Infer(src)
	if err != nil || len(res) != 1 || res[0].Type != "int" {
		t.Errorf("got %v, %v", res, err)
	}
	// A pair nested 2000 deep.
	src = "fun x -> " + strings.Repeat("(1, ", 2000) + "x" + strings.Repeat(")", 2000) + ";;"
	res, err = typeinfer.Infer(src)
	if err != nil || len(res) != 1 || res[0].Err != nil {
		t.Errorf("got %v, %v", res, err)
	}
}

func ExampleInfer() {
	results, _ := typeinfer.Infer(`
let compose f g x = f (g x);;
let rec len l = if null l then 0 else 1 + len (tl l);;
fun x -> x x;;
`)
	for _, r := range results {
		os.Stdout.WriteString(r.String() + "\n")
	}
	// Output:
	// compose : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b
	// len : 'a list -> int
	// error: occurs
}
