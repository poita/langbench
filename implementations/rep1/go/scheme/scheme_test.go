package scheme_test

import (
	"bytes"
	"strings"
	"testing"

	"example.com/scheme"
)

// run evaluates src and returns everything the CLI would print.
func run(t testing.TB, src string) string {
	t.Helper()
	var buf bytes.Buffer
	in := scheme.New(&buf)
	if err := in.Run(src); err != nil {
		var e *scheme.Error
		if asErr(err, &e) {
			buf.WriteString("error: " + string(e.Kind) + "\n")
		} else {
			t.Fatalf("unexpected error: %v", err)
		}
	}
	return buf.String()
}

func asErr(err error, target **scheme.Error) bool {
	e, ok := err.(*scheme.Error)
	if ok {
		*target = e
	}
	return ok
}

func TestPrograms(t *testing.T) {
	tests := []struct {
		name, src, want string
	}{
		{"empty", ``, ""},
		{"comment", "; hi\n", ""},
		{"literals", `42 -0 +5 #t #f "a\"b\n" 'sym '() '(1 . 2) '(1 (2 3) . 4)`,
			"42\n0\n5\n#t\n#f\n\"a\\\"b\\n\"\nsym\n()\n(1 . 2)\n(1 (2 3) . 4)\n"},
		{"quote nested", `''a`, "(quote a)\n"},
		{"void hidden", `(define x 1) (if #f #f) (display "x")`, "x"},
		{"void nested", `(list (if #f #f) car)`, "(#<void> #<procedure>)\n"},
		{"display", `(display '("x" y 1)) (newline) (write-test)`, "(x y 1)\nerror: unbound-variable\n"},
		{"arith", `(+) (*) (- 5) (- 10 1 2) (quotient -7 2) (remainder -7 2) (quotient 7 -2) (remainder 7 -2)`,
			"0\n1\n-5\n7\n-3\n-1\n-3\n1\n"},
		{"compare", `(< 1 2 3) (< 1 3 2) (= 2 2 2) (>= 3 3 1)`, "#t\n#f\n#t\n#t\n"},
		{"overflow", `(* 4611686018427387904 2) (- -9223372036854775808 1) (+ 9223372036854775807 1)`,
			"9223372036854775808\n-9223372036854775809\n9223372036854775808\n"},
		{"big back to fixnum", `(- (+ 9223372036854775807 1) 1)`, "9223372036854775807\n"},
		{"big eq", `(eq? (* 99999999999 99999999999) (* 99999999999 99999999999))`, "#t\n"},
		{"closure counter", `(define (mk) (let ((n 0)) (lambda () (set! n (+ n 1)) n)))
(define c (mk)) (c) (c)`, "1\n2\n"},
		{"rest args", `((lambda (a . r) r) 1 2 3) ((lambda r r))`, "(2 3)\n()\n"},
		{"named let scope", `(define loop 'outer) (let loop ((i 0)) (if (< i 3) (loop (+ i 1)) i))`, "3\n"},
		{"let star frames", `(let* ((a 1) (b (+ a 1))) (define c 10) (+ a b c))`, "13\n"},
		{"letrec", `(letrec ((ev? (lambda (n) (if (= n 0) #t (od? (- n 1))))) (od? (lambda (n) (if (= n 0) #f (ev? (- n 1)))))) (ev? 10))`, "#t\n"},
		{"cond", `(cond (#f 1) (5) (else 3)) (cond (#f 1)) (cond (#f 1) (else 2))`, "5\n2\n"},
		{"and or", `(and) (or) (and 1 2) (or #f 3) (and 1 #f 3)`, "#t\n#f\n2\n3\n#f\n"},
		{"internal define", `(define (f) (define a 1) (define (g) a) (g)) (f)`, "1\n"},
		{"apply", `(apply + 1 2 '(3 4)) (apply apply (list + (list 1 2)))`, "10\n3\n"},
		{"strings", `(string-append "a" "b") (string-length "hello") (number->string -12) (symbol->string 'abc)`,
			"\"ab\"\n5\n\"-12\"\n\"abc\"\n"},
		{"equal", `(equal? '(1 (2 "x")) '(1 (2 "x"))) (eq? '(1) '(1)) (eq? 'a 'a) (equal? 1 2)`, "#t\n#f\n#t\n#f\n"},
		{"eval order", `(list (begin (display "a") 1) (begin (display "b") 2))`, "ab(1 2)\n"},
		{"tail loop", `(let loop ((i 0)) (if (< i 1000000) (loop (+ i 1)) i))`, "1000000\n"},
		{"tail apply", `(define (f n) (if (= n 0) 'done (apply f (list (- n 1))))) (f 300000)`, "done\n"},
		{"deep recursion", `(define (f n) (if (= n 0) 0 (+ 1 (f (- n 1))))) (f 10000)`, "10000\n"},
		{"factorial", `(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (fact 25)`, "15511210043330985984000000\n"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := run(t, tc.src); got != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestErrors(t *testing.T) {
	tests := []struct{ name, src, want string }{
		{"unbound", `(foo)`, "error: unbound-variable\n"},
		{"set unbound keeps output", `(set! zz (display "hi"))`, "hierror: unbound-variable\n"},
		{"not a procedure", `(1 2)`, "error: type-error\n"},
		{"operands first", `((display "x") (display "y"))`, "xyerror: type-error\n"},
		{"car", `(car '())`, "error: type-error\n"},
		{"arith type", `(+ 1 "a")`, "error: type-error\n"},
		{"all args checked", `(< 2 1 "x")`, "error: type-error\n"},
		{"arity closure", `((lambda (x) x))`, "error: arity-error\n"},
		{"arity closure many", `((lambda (x) x) 1 2)`, "error: arity-error\n"},
		{"arity prim", `(car (display "x") (display "y"))`, "xyerror: arity-error\n"},
		{"div zero", `(quotient 1 0)`, "error: division-by-zero\n"},
		{"rem zero", `(remainder 1 0)`, "error: division-by-zero\n"},
		{"user", `(error "boom" 1 2)`, "error: user-error\n"},
		{"apply improper", `(apply + 1 2)`, "error: type-error\n"},
		{"stops", "(display 1) (car 1) (display 2)", "1error: type-error\n"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := run(t, tc.src); got != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestReader(t *testing.T) {
	vs, err := scheme.ReadAll("(1 . (2 3)) 'x \"s\" foo ; c\n 1+ ...")
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, v := range vs {
		got = append(got, scheme.Write(v))
	}
	want := "(1 2 3)|(quote x)|\"s\"|foo|1+|..."
	if strings.Join(got, "|") != want {
		t.Errorf("got %s, want %s", strings.Join(got, "|"), want)
	}
	for _, bad := range []string{"(1 2", ")", "\"abc"} {
		if _, err := scheme.ReadAll(bad); err == nil {
			t.Errorf("ReadAll(%q) should fail", bad)
		}
	}
}

func TestLibraryAPI(t *testing.T) {
	var buf bytes.Buffer
	in := scheme.New(&buf)
	in.DefinePrimitive("double", 1, 1, func(_ *scheme.Interp, a []scheme.Value) scheme.Value {
		n, ok := a[0].(scheme.Int)
		if !ok {
			scheme.Raise(scheme.ErrType)
		}
		return n * 2
	})
	v, err := in.Eval(`(define (f x) (double x)) (f 21)`)
	if err != nil || v != scheme.Value(scheme.Int(42)) {
		t.Fatalf("Eval = %v, %v", v, err)
	}
	f, _ := in.Lookup("f")
	v, err = in.Call(f, scheme.Int(5))
	if err != nil || scheme.Write(v) != "10" {
		t.Fatalf("Call = %v, %v", v, err)
	}
	if _, err := in.Call(f, scheme.NewString("x")); err == nil {
		t.Fatal("expected a type error")
	} else if e, ok := err.(*scheme.Error); !ok || e.Kind != scheme.ErrType {
		t.Fatalf("got %v", err)
	}
	if got := scheme.Display(scheme.List(scheme.NewString("a"), scheme.Int(1))); got != "(a 1)" {
		t.Errorf("Display = %q", got)
	}
}

func BenchmarkFib(b *testing.B) {
	src := `(define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 20)`
	for i := 0; i < b.N; i++ {
		in := scheme.New(&bytes.Buffer{})
		if err := in.Run(src); err != nil {
			b.Fatal(err)
		}
	}
}
