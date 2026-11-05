package check_test

import (
	"strings"
	"testing"

	"langvm/vellum"
)

// diagCase is a whole input with the diagnostic it must produce ("" = accepted).
type diagCase struct {
	name string
	src  string
	want string
}

func run(t *testing.T, cases []diagCase) {
	t.Helper()
	for _, c := range cases {
		_, err := vellum.Check([]byte(c.src))
		got := ""
		if err != nil {
			got = err.Error()
		}
		if got != c.want {
			t.Errorf("%s: got %q, want %q\n%s", c.name, got, c.want, c.src)
		}
	}
}

func main1(body string) string { return "@module main\n" + body + "\n" }

func TestPassOrder(t *testing.T) {
	run(t, []diagCase{
		{"lex beats parse", "@module main\nfn main() { let x = ; }\n@module b\nlet \x60", "error: bad-token at 1:5"},
		{"parse beats items", "@module main\nstruct Int {}\nfn main( {", "error: parse at 2:10"},
		{"items beat bodies", main1("fn main() { let x: Int = \"s\"; }\nstruct Int {}"), "error: reserved-name at 2:8"},
		{"no-main", "@module main\nfn f() {}", "error: no-main at 1:1"},
		{"main with params", main1("fn main(x: Int) {}"), "error: no-main at 1:1"},
		{"main returning Int", main1("fn main() -> Int { 1 }"), "error: no-main at 1:1"},
		{"missing-return after body errors", main1("fn f() -> Int { let x: Int = true; }\nfn main() {}"), "error: type-mismatch at 1:30"},
	})
}

func TestItems(t *testing.T) {
	run(t, []diagCase{
		{"dup fn", main1("fn f() {}\nfn f() {}\nfn main() {}"), "error: dup-name at 2:4"},
		{"dup variant", main1("enum E { A, B, A }\nfn main() {}"), "error: dup-name at 1:16"},
		{"same name different namespaces", main1("struct P {}\nfn P() {}\nfn main() {}"), ""},
		{"dup param", main1("fn f(a: Int, a: Int) {}\nfn main() {}"), "error: dup-name at 1:14"},
		{"dup type param", main1("fn f<T, T>() {}\nfn main() {}"), "error: dup-name at 1:9"},
		{"unknown use", main1("use nope;\nfn main() {}"), "error: unknown-module at 1:5"},
		{"unknown type", main1("fn f(x: Nope) {}\nfn main() {}"), "error: unknown-type at 1:9"},
		{"unknown trait", main1("fn f<T: Nope>(x: T) {}\nfn main() {}"), "error: unknown-trait at 1:9"},
		{"arity-type", main1("struct S<T> { x: T }\nfn f(x: S) {}\nfn main() {}"), "error: arity-type at 2:9"},
		{"arity-type on primitive", main1("fn f(x: Int<Int>) {}\nfn main() {}"), "error: arity-type at 1:9"},
		{"self outside", main1("fn f(x: Self) {}\nfn main() {}"), "error: self-outside at 1:9"},
		{"bad key type", main1("fn f(x: #[Float: Int]) {}\nfn main() {}"), "error: bad-key-type at 1:9"},
		{"key param without bound", main1("fn f<K>(x: #[K: Int]) {}\nfn main() {}"), "error: bad-key-type at 1:12"},
		{"key param with bound", main1("fn f<K: Key>(x: #[K: Int]) {}\nfn main() {}"), ""},
		{"builtin trait impl", main1("impl Eq for Int {}\nfn main() {}"), "error: builtin-trait-impl at 1:1"},
		{"bad impl head", main1("trait T {}\nimpl T for [Int] {}\nfn main() {}"), "error: bad-impl-head at 2:12"},
		{"unused param", main1("trait T {}\nimpl<A, B> T for [A] {}\nfn main() {}"), "error: unused-param at 2:9"},
		{"dup impl", main1("trait T {}\nimpl T for Int {}\nimpl T for Int {}\nfn main() {}"), "error: dup-impl at 3:1"},
		{"missing method", main1("trait T { fn a(self); }\nimpl T for Int {}\nfn main() {}"), "error: missing-method at 2:1"},
		{"extra method", main1("trait T {}\nimpl T for Int { fn a(self) {} }\nfn main() {}"), "error: extra-method at 2:21"},
		{"sig mismatch", main1("trait T { fn a(self) -> Int; }\nimpl T for Int { fn a(self) -> Str { \"\" } }\nfn main() {}"), "error: sig-mismatch at 2:21"},
		{"default method ok", main1("trait T { fn a(self) -> Int { 1 } }\nimpl T for Int {}\nfn main() {}"), ""},
	})
}

func TestModules(t *testing.T) {
	run(t, []diagCase{
		{"not public", "@module main\nuse m;\nfn main() { m::f(); }\n@module m\nfn f() {}", "error: not-public at 2:16"},
		{"public", "@module main\nuse m;\nfn main() { m::f(); }\n@module m\npub fn f() {}", ""},
		{"unknown module qualifier", main1("fn main() { zz::f(); }"), "error: unknown-module at 1:13"},
		{"alias", "@module main\nuse m as k;\nfn main() { k::f(); }\n@module m\npub fn f() {}", ""},
		{"self import allows private", main1("use main;\nfn p() {}\nfn main() { main::p(); }"), ""},
		{"cyclic imports", "@module main\nuse a;\nfn main() { a::f(); }\n@module a\nuse main;\npub fn f() { main::main(); }", "error: not-public at 2:20"},
	})
}

func TestExpressions(t *testing.T) {
	run(t, []diagCase{
		{"example 12", main1("fn main() {\n    let n: Int = 1;\n    print(n + \"x\");\n}"), "error: type-mismatch at 3:15"},
		{"unknown name", main1("fn main() { x; }"), "error: unknown-name at 1:13"},
		{"arity", main1("fn f(a: Int) {}\nfn main() { f(); }"), "error: arity at 2:13"},
		{"bad arity 17 args", main1("fn main() { print(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17); }"), "error: bad-arity at 1:13"},
		{"not callable", main1("fn main() { let x = 1; x(); }"), "error: not-callable at 1:24"},
		{"not struct", main1("fn main() { let x = 1; x.a; }"), "error: not-struct at 1:24"},
		{"unknown field", main1("struct S { a: Int }\nfn main() { let s = S.{ a: 1 }; s.b; }"), "error: unknown-field at 2:35"},
		{"dup field", main1("struct S { a: Int }\nfn main() { let s = S.{ a: 1, a: 2 }; }"), "error: dup-field at 2:31"},
		{"not indexable", main1("fn main() { let x = 1; x[0]; }"), "error: not-indexable at 1:24"},
		{"not eq", main1("fn main() { let f = |x: Int| x; f == f; }"), "error: not-eq at 1:33"},
		{"not ord", main1("fn main() { [1] < [2]; }"), "error: not-ord at 1:13"},
		{"cannot infer empty list", main1("fn main() { var xs = []; }"), "error: cannot-infer at 1:22"},
		{"expected type solves None", main1("fn main() { let x: Option<Int> = None; }"), ""},
		{"None without type", main1("fn main() { let x = None; }"), "error: cannot-infer at 1:21"},
		{"missing return", main1("fn f() -> Int { let x = 1; }\nfn main() {}"), "error: missing-return at 1:1"},
		{"diverging body", main1("fn f() -> Int { return 1; }\nfn main() {}"), ""},
		{"assign immutable", main1("fn main() { let x = 1; x = 2; }"), "error: assign-immutable at 1:24"},
		{"assign captured", main1("fn main() { var x = 1; let g = || { x = 2; }; }"), "error: assign-captured at 1:37"},
		{"bad target", main1("fn main() { 1 = 2; }"), "error: bad-target at 1:13"},
		{"break outside lambda", main1("fn main() { while true { let g = || { break; }; } }"), "error: break-outside at 1:39"},
		{"unsatisfied bound", main1("trait A { fn a(self); }\nfn f<T: A>(x: T) {}\nfn main() { f(1); }"), "error: unsatisfied-bound at 3:13"},
		{"ambiguous method", main1("trait A { fn go(self); }\ntrait B { fn go(self); }\nimpl A for Int { fn go(self) {} }\nimpl B for Int { fn go(self) {} }\nfn main() { 3.go(); }"), "error: ambig-method at 5:15"},
		{"no method", main1("fn main() { 3.go(); }"), "error: no-method at 1:15"},
		{"lambda needs annotation", main1("fn main() { let f = |x| x; }"), "error: cannot-infer at 1:22"},
		{"lambda checked", main1("fn main() { let r = listMap([1], |x| x + 1); }"), ""},
		{"return in unit function", main1("fn main() { return 5; }"), "error: type-mismatch at 1:13"},
		{"tuple too long", main1("fn main() { let t = (1,2,3,4,5,6,7,8,9); }"), "error: bad-arity at 1:21"},
	})
}

func TestPatterns(t *testing.T) {
	run(t, []diagCase{
		{"non exhaustive", main1("enum E { A, B }\nfn f(e: E) -> Int { match e { A -> 1 } }\nfn main() {}"), "error: non-exhaustive at 2:21"},
		{"unreachable", main1("fn main() { match 3 { _ -> {}, 1 -> {} } }"), "error: unreachable at 1:32"},
		{"list patterns exhaustive", main1("fn f(xs: [Int]) -> Int { match xs { [] -> 0, [a] -> a, [a, b, ..] -> a + b } }\nfn main() {}"), ""},
		{"guard does not cover", main1("fn f(b: Bool) -> Int { match b { true when false -> 1, false -> 2 } }\nfn main() {}"), "error: non-exhaustive at 1:24"},
		{"float pattern", main1("fn main() { match 1.5 { 1.5 -> {}, _ -> {} } }"), "error: bad-pattern at 1:25"},
		{"refutable let", main1("fn main() { let [a] = [1]; }"), "error: refutable-pattern at 1:17"},
		{"dup binding", main1("fn main() { let (a, a) = (1, 2); }"), "error: dup-name at 1:21"},
		{"missing field in pattern", main1("struct S { a: Int, b: Int }\nfn main() { let S.{ a } = S.{ a: 1, b: 2 }; }"), "error: missing-field at 2:17"},
		{"empty enum wildcard unreachable", main1("enum V {}\nfn f(v: V) -> Int { match v { _ -> 0 } }\nfn main() {}"), "error: unreachable at 2:31"},
	})
}

func TestProgramShape(t *testing.T) {
	prog, err := vellum.Check([]byte(main1("fn main() {}")))
	if err != nil {
		t.Fatal(err)
	}
	if prog.Main == nil || prog.Main.Name != "main" {
		t.Fatalf("Main not set")
	}
	if !strings.HasPrefix(prog.Types[0].Name, "Option") || prog.Types[1].Name != "Result" {
		t.Fatalf("prelude types must have ids 0 and 1")
	}
}
