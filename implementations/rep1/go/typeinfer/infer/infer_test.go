package infer

import (
	"errors"
	"testing"

	"github.com/example/typeinfer/syntax"
)

// run infers a program and returns one line per declaration.
func run(t *testing.T, src string) []string {
	t.Helper()
	decls, err := syntax.ParseProgram(src)
	if err != nil {
		t.Fatal(err)
	}
	in := New()
	var out []string
	for _, d := range decls {
		res, err := in.Infer(d)
		var e *Error
		switch {
		case errors.As(err, &e):
			out = append(out, "error: "+string(e.Kind))
		case err != nil:
			t.Fatal(err)
		case res.Name == "":
			out = append(out, "- : "+res.Scheme.String())
		default:
			out = append(out, res.Name+" : "+res.Scheme.String())
		}
	}
	return out
}

func check(t *testing.T, src string, want ...string) {
	t.Helper()
	got := run(t, src)
	if len(got) != len(want) {
		t.Fatalf("%q: got %q, want %q", src, got, want)
	}
	for i := range got {
		if got[i] != want[i] {
			t.Errorf("%q decl %d: got %q, want %q", src, i, got[i], want[i])
		}
	}
}

func TestBuiltins(t *testing.T) {
	check(t, "not;; fst;; snd;; hd;; tl;; null;; length;; map;; fold;;",
		"- : bool -> bool",
		"- : 'a * 'b -> 'a",
		"- : 'a * 'b -> 'b",
		"- : 'a list -> 'a",
		"- : 'a list -> 'a list",
		"- : 'a list -> bool",
		"- : 'a list -> int",
		"- : ('a -> 'b) -> 'a list -> 'b list",
		"- : ('a -> 'b -> 'a) -> 'a -> 'b list -> 'a",
	)
}

func TestLetPolymorphism(t *testing.T) {
	check(t, "let id = fun x -> x;; let g = id id;; (g 1, g true);; let h = (fun x -> x) (fun y -> y);;",
		"id : 'a -> 'a", "g : 'a -> 'a", "- : int * bool", "h : 'a -> 'a")
	check(t, "fun f -> (f 1, f true);;", "error: unify")
	check(t, "let f = fun x -> let y = x in (y, y);;", "f : 'a -> 'a * 'a")
}

func TestNoValueRestriction(t *testing.T) {
	check(t, "let r = map (fun x -> x);; (r [1], r [true]);;", "r : 'a list -> 'a list", "- : int list * bool list")
}

func TestLetRec(t *testing.T) {
	check(t, "let rec len l = if null l then 0 else 1 + len (tl l);; len [true];;", "len : 'a list -> int", "- : int")
	check(t, "let rec f x = f 1 + f true;;", "error: unify")
	check(t, "let rec f x = f;;", "error: occurs")
	check(t, "(let rec f x = if x then 1 else f true in f);;", "- : bool -> int")
}

func TestScoping(t *testing.T) {
	check(t, "let map = 3;; map;;", "map : int", "- : int")
	check(t, "let x = x + 1;;", "error: unbound")
	check(t, "let x = true;; let y = (let x = x in x + 1);;", "x : bool", "error: unify")
	check(t, "let rec f x = f;; f;;", "error: occurs", "error: unbound")
	check(t, "let f = 1;; let f = f true;; f;;", "f : int", "error: unify", "- : int")
}

func TestErrorKindOrder(t *testing.T) {
	check(t, "fun x -> if true then (x, 0) else ([x], true);;", "error: occurs")
	check(t, "true + undefined;;", "error: unify")
	check(t, "undefined + true;;", "error: unbound")
	check(t, "fun x -> x x;;", "error: occurs")
	check(t, "1 :: [true];;", "error: unify")
	check(t, "[1; true; z];;", "error: unify")
	check(t, "if 1 then z else 2;;", "error: unify")
}

func TestTupleArity(t *testing.T) {
	check(t, "(1, 2) = (1, 2, 3);;", "error: unify")
	check(t, "(1, 2, 3);; ((1, 2), 3);;", "- : int * int * int", "- : (int * int) * int")
}

func TestOperators(t *testing.T) {
	check(t, "1 < 2 && 3 >= 4 || true;; true = false;; 1 :: 2 :: [];;",
		"- : bool", "error: unify", "- : int list")
}

func TestFailedDeclarationAddsNothing(t *testing.T) {
	check(t, "let x = 1;; let x = true + 1;; x;;", "x : int", "error: unify", "- : int")
}

func TestSpecExamples(t *testing.T) {
	check(t, `let succ n = fun f x -> f (n f x);;
let add m n = fun f x -> m f (n f x);;
fun x -> x x;;
let g = id id;;
let id = fun x -> x;;
let g = id id;;
(g 1, g true);;
[fun p -> (snd p, fst p)];;`,
		"succ : (('a -> 'b) -> 'c -> 'a) -> ('a -> 'b) -> 'c -> 'b",
		"add : ('a -> 'b -> 'c) -> ('a -> 'd -> 'b) -> 'a -> 'd -> 'c",
		"error: occurs", "error: unbound", "id : 'a -> 'a", "g : 'a -> 'a", "- : int * bool",
		"- : ('a * 'b -> 'b * 'a) list")
	check(t, "fun a b c -> let p = (a, b) in (fun x -> [x; c], p, fst p);;",
		"- : 'a -> 'b -> 'c -> ('c -> 'c list) * ('a * 'b) * 'a")
}

func TestUnboundErrorCarriesName(t *testing.T) {
	d, _ := syntax.ParseProgram("foo;;")
	_, err := New().Infer(d[0])
	var e *Error
	if !errors.As(err, &e) || e.Kind != Unbound || e.Name != "foo" {
		t.Errorf("got %v", err)
	}
}

func TestInferersAreIndependent(t *testing.T) {
	d, _ := syntax.ParseProgram("let x = 1;; x;;")
	a, b := New(), New()
	if _, err := a.Infer(d[0]); err != nil {
		t.Fatal(err)
	}
	if _, err := b.Infer(d[1]); err == nil {
		t.Error("x should be unbound in a fresh Inferer")
	}
}
