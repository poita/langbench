package check_test

import (
	"strings"
	"testing"

	"langvm"
)

// compileErr returns the diagnostic text for a one-module program, or "".
func compileErr(src string) string {
	_, d := langvm.Compile([]byte("@module main\n" + src))
	if d == nil {
		return ""
	}
	return d.Error()
}

func TestDiagnostics(t *testing.T) {
	cases := []struct{ name, src, want string }{
		{"no main", "fn f() {}", "error: no-main at 1:1"},
		{"reserved", "struct Int {} fn main() {}", "error: reserved-name at 1:8"},
		{"dup name", "fn f() {} fn f() {} fn main() {}", "error: dup-name at 1:14"},
		{"unknown type", "fn f(x: Nope) {} fn main() {}", "error: unknown-type at 1:9"},
		{"arity type", "fn f(x: Option) {} fn main() {}", "error: arity-type at 1:9"},
		{"self outside", "fn f(x: Self) {} fn main() {}", "error: self-outside at 1:9"},
		{"bad key", "fn f(x: #[Float: Int]) {} fn main() {}", "error: bad-key-type at 1:9"},
		{"unknown name", "fn main() { y; }", "error: unknown-name at 1:13"},
		{"type mismatch", "fn main() { let x: Int = \"s\"; }", "error: type-mismatch at 1:26"},
		{"cannot infer", "fn main() { let x = None; }", "error: cannot-infer at 1:21"},
		{"missing return", "fn f() -> Int { } fn main() {}", "error: missing-return at 1:1"},
		{"assign immutable", "fn main() { let x = 1; x = 2; }", "error: assign-immutable at 1:24"},
		{"break outside", "fn main() { break; }", "error: break-outside at 1:13"},
		{"non exhaustive", "fn main() { match true { true -> {} } }", "error: non-exhaustive at 1:13"},
		{"unreachable", "fn main() { match 1 { _ -> {}, 2 -> {} } }", "error: unreachable at 1:32"},
		{"not eq", "fn main() { let f = |x: Int| x; f == f; }", "error: not-eq at 1:33"},
		{"not ord", "fn main() { (1, 2) < (1, 2); }", "error: not-ord at 1:13"},
		{"bad pattern", "fn main() { match 1.0 { 1.5 -> {}, _ -> {} } }", "error: bad-pattern at 1:25"},
		{"refutable", "fn main() { let Some(x) = Some(1); }", "error: refutable-pattern at 1:17"},
		{"missing field", "struct S { a: Int } fn main() { let s = S.{}; }", "error: missing-field at 1:41"},
		{"no method", "fn main() { 1.nope(); }", "error: no-method at 1:15"},
		{"bad value ref", "fn main() { let f = print; }", "error: bad-value-ref at 1:21"},
		{"builtin impl", "struct S {} impl Eq for S {} fn main() {}", "error: builtin-trait-impl at 1:13"},
		{"bad impl head", "trait T { fn f(self); } impl T for [Int] { fn f(self) {} } fn main() {}", "error: bad-impl-head at 1:36"},
		{"missing method", "trait T { fn f(self); } impl T for Int {} fn main() {}", "error: missing-method at 1:25"},
		{"unsatisfied", "trait T { fn f(self); } fn g<A: T>(a: A) {} fn main() { g(1); }", "error: unsatisfied-bound at 1:57"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := compileErr(c.src); got != c.want {
				t.Errorf("got %q, want %q", got, c.want)
			}
		})
	}
}

func TestAccepts(t *testing.T) {
	progs := []string{
		"fn main() { let xs = [1, 2]; for x in xs { print(showInt(x)); } }",
		"enum E { A, B(Int) } fn f(e: E) -> Int { match e { A -> 0, B(n) when n > 0 -> n, B(_) -> 1 } } fn main() {}",
		"trait T { fn f(self) -> Int { 1 } } impl T for Int {} fn main() { print(showInt(1.f())); }",
		"fn main() { let m: #[Str: [Int]] = #[]; mapSet(m, \"a\", []); }",
	}
	for _, p := range progs {
		if got := compileErr(p); got != "" {
			t.Errorf("%q rejected: %s", p, got)
		}
	}
}

func TestPassOrder(t *testing.T) {
	// A parse error in a later module beats a type error in an earlier one.
	_, d := langvm.Compile([]byte("@module main\nfn main() { let x: Int = \"s\"; }\n@module other\nfn f( {\n}\n"))
	if d == nil || !strings.HasPrefix(d.Error(), "error: parse at 1:7") {
		t.Errorf("got %v", d)
	}
}
