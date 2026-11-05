package typeinfer_test

import (
	"strings"
	"testing"

	"example.com/typeinfer"
)

// run checks src with a fresh checker and returns the output lines.
func run(t *testing.T, src string) []string {
	t.Helper()
	results, err := typeinfer.Infer(src)
	if err != nil {
		t.Fatalf("Infer: %v", err)
	}
	lines := make([]string, len(results))
	for i, r := range results {
		lines[i] = r.String()
	}
	return lines
}

func expect(t *testing.T, src string, want ...string) {
	t.Helper()
	got := run(t, src)
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("program %q\n got: %q\nwant: %q", src, got, want)
	}
}

func TestSpecExamples(t *testing.T) {
	expect(t, `
let id = fun x -> x;;
let compose f g x = f (g x);;
compose;;
let rec len l = if null l then 0 else 1 + len (tl l);;
(id 1, id true, len [true]);;
fun f -> (f 1, f true);;`,
		"id : 'a -> 'a",
		"compose : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b",
		"- : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b",
		"len : 'a list -> int",
		"- : int * bool * int",
		"error: unify")

	expect(t, `
let succ n = fun f x -> f (n f x);;
let add m n = fun f x -> m f (n f x);;
fun x -> x x;;
let g = id id;;
let id = fun x -> x;;
let g = id id;;
(g 1, g true);;
[fun p -> (snd p, fst p)];;`,
		"succ : (('a -> 'b) -> 'c -> 'a) -> ('a -> 'b) -> 'c -> 'b",
		"add : ('a -> 'b -> 'c) -> ('a -> 'd -> 'b) -> 'a -> 'd -> 'c",
		"error: occurs",
		"error: unbound",
		"id : 'a -> 'a",
		"g : 'a -> 'a",
		"- : int * bool",
		"- : ('a * 'b -> 'b * 'a) list")

	expect(t, `
let map = 3;;
map;;
fun a b c -> let p = (a, b) in (fun x -> [x; c], p, fst p);;
let rec bad x = bad 1 + bad true;;
1 :: [true];;`,
		"map : int",
		"- : int",
		"- : 'a -> 'b -> 'c -> ('c -> 'c list) * ('a * 'b) * 'a",
		"error: unify",
		"error: unify")
}

func TestEmptyProgram(t *testing.T) {
	expect(t, "")
	expect(t, " \n\t ")
}

func TestBuiltins(t *testing.T) {
	c := typeinfer.NewChecker()
	want := map[string]string{
		"not":    "bool -> bool",
		"fst":    "'a * 'b -> 'a",
		"snd":    "'a * 'b -> 'b",
		"hd":     "'a list -> 'a",
		"tl":     "'a list -> 'a list",
		"null":   "'a list -> bool",
		"length": "'a list -> int",
		"map":    "('a -> 'b) -> 'a list -> 'b list",
		"fold":   "('a -> 'b -> 'a) -> 'a -> 'b list -> 'a",
	}
	for name, ty := range want {
		got, ok := c.TypeOf(name)
		if !ok || got != ty {
			t.Errorf("TypeOf(%s) = %q, %v; want %q", name, got, ok, ty)
		}
	}
	if _, ok := c.TypeOf("nosuchname"); ok {
		t.Error("TypeOf(nosuchname) found")
	}
}

func TestLiteralsAndOperators(t *testing.T) {
	expect(t, "1;; true;; ();; [];; 1 + 2 * 3 - 4 / 5;; 1 < 2;; 1 = 2 && true || false;; 0 - 5;;",
		"- : int", "- : bool", "- : unit", "- : 'a list", "- : int", "- : bool", "- : bool", "- : int")
	expect(t, "true = false;; 1 && 2;; not 1;;", "error: unify", "error: unify", "error: unify")
}

func TestShadowingAndScope(t *testing.T) {
	expect(t, "let x = 1;; let x = true;; x;;", "x : int", "x : bool", "- : bool")
	expect(t, "(let x = x + 1 in x);;", "error: unbound")
	expect(t, "let x = 1;; let y = (let x = true in x);; x;;", "x : int", "y : bool", "- : int")
	expect(t, "let x = 1;; let x = x + 1;; x;;", "x : int", "x : int", "- : int")
	expect(t, "fun x -> fun x -> x;;", "- : 'a -> 'b -> 'b")
	expect(t, "let not = 1;; not;;", "not : int", "- : int")
}

func TestFailedDeclarationBindsNothing(t *testing.T) {
	expect(t, "let f = 1;; let f = f true;; f;;", "f : int", "error: unify", "- : int")
	expect(t, "let f = g;; f;;", "error: unbound", "error: unbound")
	expect(t, "let rec r x = r;; r;;", "error: occurs", "error: unbound")
}

func TestLetPolymorphism(t *testing.T) {
	expect(t, "let g = id id;;", "error: unbound")
	expect(t, "let id x = x;; let g = id id;; (g 1, g true);;", "id : 'a -> 'a", "g : 'a -> 'a", "- : int * bool")
	expect(t, "fun x -> let y = x in (y 1, y true);;", "error: unify")
	expect(t, "fun x -> let y = x in y;;", "- : 'a -> 'a")
	// A lambda-bound variable stays monomorphic even after a let.
	expect(t, "fun f -> let g = f in (g 1, g true);;", "error: unify")
	// Variables free in the environment are not generalised.
	expect(t, "fun x -> let y = (x, x) in y;;", "- : 'a -> 'a * 'a")
}

func TestLetRec(t *testing.T) {
	expect(t, "let rec f x = f 1 + f true;;", "error: unify")
	expect(t, "let rec fact n = if n < 1 then 1 else n * fact (n - 1);;", "fact : int -> int")
	expect(t, "let rec loop x = loop x;;", "loop : 'a -> 'b")
	expect(t, "let rec ev n = if n = 0 then true else not (ev (n - 1));; ev;;", "ev : int -> bool", "- : int -> bool")
	expect(t, "(let rec f x = x in (f 1, f true));;", "- : int * bool")
	expect(t, "let rec map2 f l = if null l then [] else f (hd l) :: map2 f (tl l);;",
		"map2 : ('a -> 'b) -> 'a list -> 'b list")
}

func TestErrorKinds(t *testing.T) {
	expect(t, "fun x -> x x;;", "error: occurs")
	expect(t, "1 2;;", "error: unify")
	expect(t, "if 1 then 2 else 3;;", "error: unify")
	expect(t, "if true then 1 else false;;", "error: unify")
	expect(t, "(1, 2) = (1, 2);;", "error: unify")
	expect(t, "fst (1, 2, 3);;", "error: unify")
	expect(t, "[1; true];;", "error: unify")
	expect(t, "undefined;;", "error: unbound")
	expect(t, "fun x -> [x; [x]];;", "error: occurs")
	expect(t, "fun x -> x :: x;;", "error: occurs")
}

// The order in which problems are met decides which error is reported.
func TestErrorOrder(t *testing.T) {
	expect(t, "fun x -> if true then (x, 0) else ([x], true);;", "error: occurs")
	expect(t, "true + undefined;;", "error: unify")
	expect(t, "undefined + true;;", "error: unbound")
	expect(t, "undefined true;;", "error: unbound")
	expect(t, "not undefined;;", "error: unbound")
	expect(t, "if 1 then undefined else 2;;", "error: unify")
	expect(t, "[true; 1; undefined];;", "error: unify")
	expect(t, "[undefined; 1 2];;", "error: unbound")
	expect(t, "(let x = 1 2 in undefined);;", "error: unify")
	expect(t, "fun f -> f (fun x -> f);;", "error: occurs")
	expect(t, "(let rec f x = f in undefined);;", "error: occurs")
	// Arrow arguments are unified before results.
	expect(t, "fun f x -> (f x) + (f (x, x) 1);;", "error: occurs")
}

func TestTuples(t *testing.T) {
	expect(t, "(1, true, ());;", "- : int * bool * unit")
	expect(t, "((1, 2), 3);;", "- : (int * int) * int")
	expect(t, "(1, (2, 3));;", "- : int * (int * int)")
	expect(t, "fun p -> (fst p) + 1;;", "- : int * 'a -> int")
	expect(t, "if true then (1, 2) else (1, 2, 3);;", "error: unify")
	expect(t, "let f p = (fst p, snd p);; f (1, 2, 3);;", "f : 'a * 'b -> 'a * 'b", "error: unify")
}

func TestParserDisambiguation(t *testing.T) {
	expect(t, "(fun x -> x, 1);;", "- : ('a -> 'a) * int")
	expect(t, "[fun x -> x; fun y -> 1];;", "- : (int -> int) list")
	expect(t, "(let y = 1 in y, 2);;", "- : int * int")
	expect(t, "1 :: 2 :: [];;", "- : int list")
	expect(t, "(let f x = x + 1 in f 2 :: []);;", "- : int list")
	expect(t, "fun x y -> x + y;;", "- : int -> int -> int")
	expect(t, "(if true then fun x -> x else fun y -> y);;", "- : 'a -> 'a")
}

func TestPrinting(t *testing.T) {
	expect(t, "fun f -> f;;", "- : 'a -> 'a")
	expect(t, "fun f g -> (f, g);;", "- : 'a -> 'b -> 'a * 'b")
	expect(t, "fun f -> (f, 1);;", "- : 'a -> 'a * int")
	expect(t, "(fun x -> x, 1, (1, 2));;", "- : ('a -> 'a) * int * (int * int)")
	expect(t, "[fun x -> x];;", "- : ('a -> 'a) list")
	expect(t, "[(1, 2)];;", "- : (int * int) list")
	expect(t, "[[1]];;", "- : int list list")
	expect(t, "fun f -> f 1;;", "- : (int -> 'a) -> 'a")
	expect(t, "fun f -> fun x -> f (f x);;", "- : ('a -> 'a) -> 'a -> 'a")
	expect(t, "fun x -> (x, [x]);;", "- : 'a -> 'a * 'a list")
	expect(t, "fun x y -> (fun z -> z, [y]);;", "- : 'a -> 'b -> ('c -> 'c) * 'b list")
	expect(t, "fold;;", "- : ('a -> 'b -> 'a) -> 'a -> 'b list -> 'a")
	expect(t, "fun f -> (f, f);;", "- : 'a -> 'a * 'a")
}

func TestManyTypeVariableNames(t *testing.T) {
	// 30 parameters, returned as a tuple: 'a .. 'z then 'a1 .. 'd1.
	var params, elems []string
	for i := 0; i < 30; i++ {
		p := "p" + string(rune('a'+i%26)) + string(rune('a'+i/26))
		params = append(params, p)
		elems = append(elems, p)
	}
	src := "fun " + strings.Join(params, " ") + " -> (" + strings.Join(elems, ", ") + ");;"
	got := run(t, src)[0]
	if !strings.Contains(got, "'z -> 'a1 -> 'b1 -> 'c1 -> 'd1 -> 'a * 'b * ") {
		t.Errorf("unexpected naming: %s", got)
	}
	if !strings.HasSuffix(got, "'y * 'z * 'a1 * 'b1 * 'c1 * 'd1") {
		t.Errorf("unexpected naming: %s", got)
	}
}

func TestRenamingIsPerDeclaration(t *testing.T) {
	expect(t, "fun a b c -> c;; fun a -> a;;", "- : 'a -> 'b -> 'c -> 'c", "- : 'a -> 'a")
}

func TestIncrementalChecking(t *testing.T) {
	c := typeinfer.NewChecker()
	r1, err := c.Check([]byte("let inc x = x + 1;;"))
	if err != nil || len(r1) != 1 || r1[0].String() != "inc : int -> int" {
		t.Fatalf("first call: %v %v", r1, err)
	}
	r2, err := c.Check([]byte("inc 2;; inc true;;"))
	if err != nil || len(r2) != 2 || r2[0].String() != "- : int" || r2[1].Err != typeinfer.ErrUnify {
		t.Fatalf("second call: %v %v", r2, err)
	}
	if ty, ok := c.TypeOf("inc"); !ok || ty != "int -> int" {
		t.Errorf("TypeOf(inc) = %q, %v", ty, ok)
	}
}

func TestResultAccessors(t *testing.T) {
	rs, _ := typeinfer.Infer("let x = 1;; 2;; y;;")
	if len(rs) != 3 {
		t.Fatalf("got %d results", len(rs))
	}
	if !rs[0].OK() || rs[0].Name != "x" || rs[0].Type != "int" {
		t.Errorf("rs[0] = %+v", rs[0])
	}
	if !rs[1].OK() || rs[1].Name != "" {
		t.Errorf("rs[1] = %+v", rs[1])
	}
	if rs[2].OK() || rs[2].Err != typeinfer.ErrUnbound || rs[2].Err.String() != "unbound" {
		t.Errorf("rs[2] = %+v", rs[2])
	}
	if got := string(rs[0].Append(nil)); got != "x : int\n" {
		t.Errorf("Append = %q", got)
	}
}

func TestSyntaxErrorReturnsEarlierResults(t *testing.T) {
	rs, err := typeinfer.Infer("let a = 1;; let = ;;")
	if err == nil {
		t.Fatal("expected a syntax error")
	}
	if len(rs) != 1 || rs[0].String() != "a : int" {
		t.Errorf("results = %v", rs)
	}
}

func TestDeepNesting(t *testing.T) {
	const n = 3000
	// Nested lets, deep parentheses, long application chain, big list.
	lets := strings.Repeat("let x = 1 in ", n) + "x;;"
	expect(t, "("+lets[:len(lets)-2]+");;", "- : int")
	parens := strings.Repeat("(", n) + "1" + strings.Repeat(")", n) + ";;"
	expect(t, parens, "- : int")
	app := "fun f -> f" + strings.Repeat(" 1", 4000) + ";;"
	if got := run(t, app)[0]; !strings.HasPrefix(got, "- : (int -> int -> ") || !strings.HasSuffix(got, "-> 'a") {
		t.Errorf("application chain: %.60s...", got)
	}
	list := "[" + strings.TrimSuffix(strings.Repeat("1; ", 100000), "; ") + "];;"
	expect(t, list, "- : int list")
	cons := strings.Repeat("1 :: ", 2000) + "[];;"
	expect(t, cons, "- : int list")
}

func TestPairTowerStaysShared(t *testing.T) {
	// dup x = (x, x) applied repeatedly has 2^n leaves when expanded; the
	// type graph must stay linear so inference does not blow up.
	var b strings.Builder
	b.WriteString("let dup x = (x, x);;\n")
	b.WriteString("let t0 = dup 1;;\n")
	for i := 1; i <= 10; i++ {
		b.WriteString("let t")
		b.WriteString(itoa(i))
		b.WriteString(" = dup t")
		b.WriteString(itoa(i - 1))
		b.WriteString(";;\n")
	}
	results, err := typeinfer.Infer(b.String())
	if err != nil {
		t.Fatal(err)
	}
	// Rendering is exponential in the tower height, so keep it small: just check the early ones.
	if results[1].String() != "t0 : int * int" {
		t.Errorf("got %q", results[1])
	}
	if results[2].String() != "t1 : (int * int) * (int * int)" {
		t.Errorf("got %q", results[2])
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var d []byte
	for n > 0 {
		d = append([]byte{byte('0' + n%10)}, d...)
		n /= 10
	}
	return string(d)
}
