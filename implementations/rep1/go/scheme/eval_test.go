package scheme_test

import (
	"errors"
	"strings"
	"testing"

	"example.com/scheme"
)

// run executes src and returns the full CLI-style output, including the
// trailing "error: <category>" line if evaluation failed.
func run(t *testing.T, src string) string {
	t.Helper()
	in := scheme.New()
	err := in.Run([]byte(src))
	out := string(in.Output())
	if err != nil {
		var se *scheme.Error
		if !errors.As(err, &se) {
			t.Fatalf("unexpected error type %T", err)
		}
		out += "error: " + se.Category + "\n"
	}
	return out
}

func TestPrograms(t *testing.T) {
	cases := []struct{ name, src, want string }{
		{"empty", "", ""},
		{"comments", "; hi\n  ; there", ""},
		{"literals", `42 -7 +5 007 -0 #t #f "a\"b\\c\nd\te" 'sym '() '(1 . 2)`,
			"42\n-7\n5\n7\n0\n#t\n#f\n\"a\\\"b\\\\c\\nd\\te\"\nsym\n()\n(1 . 2)\n"},
		{"lone sign symbols", "'(+ - ... 1+ a.b)", "(+ - ... 1+ a.b)\n"},
		{"quote nesting", "''a", "(quote a)\n"},
		{"dotted", "'(1 2 . 3)", "(1 2 . 3)\n"},
		{"define void", "(define x 3) x", "3\n"},
		{"arith", "(+) (*) (- 5) (- 10 1 2) (+ 1 2 3) (* 2 3 4)", "0\n1\n-5\n7\n6\n24\n"},
		{"quotient remainder", "(quotient -7 2) (quotient 7 -2) (remainder -7 2) (remainder 7 -2)", "-3\n-3\n-1\n1\n"},
		{"compare", "(< 1 2 3) (< 1 3 2) (= 2 2 2) (>= 3 3 2) (<= 1 1 0)", "#t\n#f\n#t\n#t\n#f\n"},
		{"bignum", "(* 99999999999 99999999999)", "9999999999800000000001\n"},
		{"fixnum overflow", "(+ 9223372036854775807 1) (- -9223372036854775808 1) (- -9223372036854775808) (quotient -9223372036854775808 -1)",
			"9223372036854775808\n-9223372036854775809\n9223372036854775808\n9223372036854775808\n"},
		{"bignum demotes", "(- (+ 9223372036854775807 1) 1)", "9223372036854775807\n"},
		{"bignum eq", "(eq? (* 99999999999 99999999999) (* 99999999999 99999999999))",
			"#t\n"},
		{"if/cond void", "(if #f #f) (cond (#f 1)) (list (if #f #f))", "(#<void>)\n"},
		{"cond forms", "(cond (#f 1) (2)) (cond (#f 1) (else 3 4))", "2\n4\n"},
		{"and/or", "(and) (or) (and 1 2) (and #f (car 0)) (or #f 3)", "#t\n#f\n2\n#f\n3\n"},
		{"closure counter", `(define (mk) (let ((n 0)) (lambda () (set! n (+ n 1)) n)))
(define c (mk)) (c) (c)`, "1\n2\n"},
		{"rest args", "((lambda (a . r) r) 1 2 3) ((lambda r r) 1 2) ((lambda (a . r) r) 1)", "(2 3)\n(1 2)\n()\n"},
		{"internal define", "(define (f) (define a 1) (define (g) (+ a 1)) (g)) (f)", "2\n"},
		{"letrec", "(letrec ((ev? (lambda (n) (if (= n 0) #t (od? (- n 1))))) (od? (lambda (n) (if (= n 0) #f (ev? (- n 1)))))) (ev? 10))", "#t\n"},
		{"let*", "(let* ((a 1) (b (+ a 1))) (list a b)) (let* () 5)", "(1 2)\n5\n"},
		{"let* define stays local", "(define k 1) (let* ((a 1)) (define k 2) k) k", "2\n1\n"},
		{"named let scope", "(define loop 10) (let loop ((i loop)) (if (= i 0) 'done (loop (- i 1))))", "done\n"},
		{"apply", "(apply + 1 2 '(3 4)) (apply list '())", "10\n()\n"},
		{"equal/eq", `(equal? '(1 (2 "x")) '(1 (2 "x"))) (eq? '(1) '(1)) (eq? 'a 'a) (eq? '() '()) (equal? "a" "a")`,
			"#t\n#f\n#t\n#t\n#t\n"},
		{"strings", `(string-append "ab" "cd") (string-length "hello") (number->string -42) (symbol->string 'foo) (string-append)`,
			"\"abcd\"\n5\n\"-42\"\n\"foo\"\n\"\"\n"},
		{"display", `(display "a\"b") (display '("x" y 1)) (newline) (display (if #f #f))`, "a\"b(x y 1)\n#<void>"},
		{"procedure print", "(list car (lambda (x) x))", "(#<procedure> #<procedure>)\n"},
		{"predicates", `(list (number? 1) (boolean? #f) (string? "") (symbol? 'a) (procedure? car) (null? '()) (pair? '()) (not 0))`,
			"(#t #t #t #t #t #t #f #f)\n"},
		{"eval order", `(define (t x) (display x) x) (list (t 1) (t 2) (t 3)) (let ((a (t 4)) (b (t 5))) a)`,
			"123(1 2 3)\n454\n"},
		{"operator before operands", `((begin (display "f") car) (begin (display "x") '(1)))`, "fx1\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := run(t, c.src); got != c.want {
				t.Errorf("got %q, want %q", got, c.want)
			}
		})
	}
}

func TestErrors(t *testing.T) {
	cases := []struct{ name, src, want string }{
		{"unbound", "(display \"a\") nope (display \"b\")", "aerror: unbound-variable\n"},
		{"set unbound keeps output", `(set! zz (display "x"))`, "xerror: unbound-variable\n"},
		{"car nil", "(car '())", "error: type-error\n"},
		{"arith type", `(+ 1 "a")`, "error: type-error\n"},
		{"compare checks all args", `(< 2 1 "x")`, "error: type-error\n"},
		{"not a procedure", "(1 2)", "error: type-error\n"},
		{"closure arity few", "((lambda (a b) a) 1)", "error: arity-error\n"},
		{"closure arity many", "((lambda (a) a) 1 2)", "error: arity-error\n"},
		{"rest arity", "((lambda (a b . r) a) 1)", "error: arity-error\n"},
		{"prim arity", "(car)", "error: arity-error\n"},
		{"prim arity before type", `(car 1 2)`, "error: arity-error\n"},
		{"operands evaluated first", `(car (display "x") (display "y"))`, "xyerror: arity-error\n"},
		{"div zero", "(quotient 1 0)", "error: division-by-zero\n"},
		{"rem zero", "(remainder 1 0)", "error: division-by-zero\n"},
		{"user error", "(error \"x\" 1 2)", "error: user-error\n"},
		{"apply improper", "(apply + 1 '(2 . 3))", "error: type-error\n"},
		{"apply non-list", "(apply + 1)", "error: type-error\n"},
		{"stops after error", "(car 1) (display \"never\")", "error: type-error\n"},
		{"string type", "(string-length 5)", "error: type-error\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := run(t, c.src); got != c.want {
				t.Errorf("got %q, want %q", got, c.want)
			}
		})
	}
}

func TestTailCallsAndDeepRecursion(t *testing.T) {
	cases := []struct{ name, src, want string }{
		{"named let", "(let loop ((i 0)) (if (< i 1000000) (loop (+ i 1)) i))", "1000000\n"},
		{"apply", "(define (f i) (if (= i 1000000) i (apply f (list (+ i 1))))) (f 0)", "1000000\n"},
		{"or", "(define (f i) (or (= i 1000000) (f (+ i 1)))) (f 0)", "#t\n"},
		{"cond", "(define (f i) (cond ((= i 1000000) i) (else (f (+ i 1))))) (f 0)", "1000000\n"},
		{"and/begin/let", "(define (f i) (and #t (begin (let ((j i)) (let* ((k j)) (letrec ((z 1)) (if (= k 300000) k (f (+ k 1))))))))) (f 0)", "300000\n"},
		{"deep non-tail", "(define (f n) (if (= n 0) 0 (+ 1 (f (- n 1))))) (f 10000)", "10000\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := run(t, c.src); got != c.want {
				t.Errorf("got %q, want %q", got, c.want)
			}
		})
	}
}

func TestFactorial2000Digits(t *testing.T) {
	got := run(t, "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (number->string (fact 2000))")
	if n := len(got) - 3; n != 5736 { // two quotes and a newline
		t.Errorf("digits = %d, want 5736", n)
	}
	if !strings.HasPrefix(got, "\"33162750924506332411753933805763240382811") {
		t.Errorf("unexpected prefix %q", got[:40])
	}
}

func TestStatePersistsAcrossRuns(t *testing.T) {
	in := scheme.New()
	if err := in.Run([]byte("(define x 5)")); err != nil {
		t.Fatal(err)
	}
	v, err := in.Eval("(* x x)")
	if err != nil {
		t.Fatal(err)
	}
	if n, ok := v.Int64(); !ok || n != 25 {
		t.Errorf("got %v", v)
	}
	// After an error the interpreter remains usable.
	if err := in.Run([]byte("(car 1)")); err == nil {
		t.Fatal("expected error")
	}
	if v, err := in.Eval("x"); err != nil || v.String() != "5" {
		t.Errorf("after error got %v, %v", v, err)
	}
}

func TestEvalAPI(t *testing.T) {
	in := scheme.New()
	v, err := in.Eval(`'(1 "two" (3 . 4))`)
	if err != nil {
		t.Fatal(err)
	}
	if v.Kind() != scheme.KindPair {
		t.Errorf("kind = %v", v.Kind())
	}
	if got, want := v.String(), `(1 "two" (3 . 4))`; got != want {
		t.Errorf("String = %s, want %s", got, want)
	}
	if got, want := v.Display(), `(1 two (3 . 4))`; got != want {
		t.Errorf("Display = %s, want %s", got, want)
	}
	if len(in.Output()) != 0 {
		t.Error("Eval must not print")
	}
	_, err = in.Eval("(nope)")
	var se *scheme.Error
	if !errors.As(err, &se) || se.Category != scheme.ErrUnboundVariable {
		t.Errorf("err = %v", err)
	}
}
