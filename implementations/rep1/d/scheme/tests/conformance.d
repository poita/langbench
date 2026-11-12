/// Black-box tests: whole programs run through `Interpreter`, checked against the specification.
module tests.conformance;

import scheme;

private string run(string program)
{
    return runToString(program);
}

unittest // spec examples
{
    assert(run(`
(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
(fact 20)
(display "done") (newline)
'(1 "two" (3 . 4) #t)
(cons 1 2)
`) == "2432902008176640000\ndone\n(1 \"two\" (3 . 4) #t)\n(1 . 2)\n");

    assert(run(`
(define (make-counter)
  (let ((n 0))
    (lambda () (set! n (+ n 1)) n)))
(define c (make-counter))
(c) (c)
(let loop ((i 0) (acc 0))
  (if (= i 1000000) acc (loop (+ i 1) (+ acc i))))
(map (lambda (x) (* x x)) '(1 2 3))
`) == "1\n2\n499999500000\nerror: unbound-variable\n");

    assert(run(`
(display "a")
(display (list 1 "b" 'c))
(newline)
(if #f #f)
(list (if #f #f) car)
(quotient 1 0)
(display "never")
`) == "a(1 b c)\n(#<void> #<procedure>)\nerror: division-by-zero\n");
}

unittest // empty and comment-only programs
{
    assert(run("") == "");
    assert(run("; nothing\n  ; here") == "");
}

unittest // integers: literals, arithmetic, bignums
{
    assert(run("42 -7 +5 007 -0") == "42\n-7\n5\n7\n0\n");
    assert(run("(+) (*) (- 5) (- 10 1 2) (+ 1 2 3) (* 2 3 4)") == "0\n1\n-5\n7\n6\n24\n");
    assert(run("(quotient -7 2) (quotient 7 -2) (remainder -7 2) (remainder 7 -2)")
            == "-3\n-3\n-1\n1\n");
    assert(run("(* 4611686018427387904 2)") == "9223372036854775808\n");
    assert(run("(- (* 4611686018427387904 2) 1)") == "9223372036854775807\n");
    assert(run("(- 0 (* 4611686018427387904 2))") == "-9223372036854775808\n");
    assert(run("(* 99999999999 99999999999 99999999999)")
            == "999999999970000000000299999999999\n");
    assert(run("(quotient 100000000000000000000000 -3)") == "-33333333333333333333333\n");
    assert(run("(remainder -100000000000000000000000 7)") == "-5\n");
    assert(run("(= 123456789012345678901234567890 123456789012345678901234567890)") == "#t\n");
    assert(run("(< 1 2 3) (< 1 3 2) (>= 3 3 2) (<= 1 1 2) (> 3 2 1) (= 1 1 2)")
            == "#t\n#f\n#t\n#t\n#t\n#f\n");
    assert(run("(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (fact 30)")
            == "265252859812191058636308480000000\n");
}

unittest // fact 2000 has 5736 digits, and dividing it back works
{
    auto got = run(`
(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
(define (div-all n k) (if (= k 0) n (div-all (quotient n k) (- k 1))))
(display (string-length (number->string (fact 2000))))
(newline)
(div-all (fact 2000) 2000)
`);
    assert(got == "5736\n1\n", got);
}

unittest // evaluation order and display
{
    assert(run(`(list (begin (display "a") 1) (begin (display "b") 2) (begin (display "c") 3))`)
            == "abc(1 2 3)\n");
    assert(run(`((begin (display "f") car) (begin (display "x") '(1)))`) == "fx1\n");
    assert(run(`(car (display "x") (display "y"))`) == "xyerror: arity-error\n");
    assert(run(`(display "a\"b") (display '("x" y))`) == "a\"b(x y)");
    assert(run(`"a\"b\\c\nd\te"`) == "\"a\\\"b\\\\c\\nd\\te\"\n");
}

unittest // define, set!, closures
{
    assert(run("(define x 1) (set! x 2) x") == "2\n");
    assert(run("(set! nope (display \"evaluated\"))") == "evaluatederror: unbound-variable\n");
    assert(run(`
(define (f x)
  (define y (* x 2))
  (define (g z) (+ y z))
  (g 1))
(f 5)`) == "11\n");
    assert(run("(define (outer) (define v 'inner) v) (define v 'global) (outer) v")
            == "inner\nglobal\n");
    assert(run("(define (f x) (define x 99) x) (f 1)") == "99\n");
    assert(run("(define (f . r) r) (f) (f 1 2)") == "()\n(1 2)\n");
    assert(run("(define (f a b . r) (list a b r)) (f 1 2) (f 1 2 3 4)") == "(1 2 ())\n(1 2 (3 4))\n");
    assert(run("((lambda r r) 1 2 3)") == "(1 2 3)\n");
}

unittest // let forms
{
    assert(run("(let () 5) (let* () 6)") == "5\n6\n");
    assert(run("(let* ((a 1) (f (lambda () a))) (define a 2) (list a (f)))") == "(2 1)\n");
    assert(run("(let* ((a 1) (a (+ a 1)) (f (lambda () a)) (a (* a 10))) (list a (f)))")
            == "(20 2)\n");
    assert(run("(define loop 5) (let loop ((x loop)) x)") == "5\n");
    assert(run("(let lp ((x 1)) (set! lp 'rebound) (list x lp))") == "(1 rebound)\n");
    assert(run(`(letrec ((ev? (lambda (n) (if (= n 0) #t (od? (- n 1)))))
                         (od? (lambda (n) (if (= n 0) #f (ev? (- n 1))))))
                  (ev? 10))`) == "#t\n");
    assert(run("(let loop ((i 0)) (if (< i 3) (loop (+ i 1)) i)) loop")
            == "3\nerror: unbound-variable\n");
}

unittest // cond, and, or, if
{
    assert(run("(cond (#f 1) (else 2)) (cond (5)) (cond (#f 1))") == "2\n5\n");
    assert(run("(and) (or) (and 1 2) (or #f 3) (and #f (car 1)) (or 4 (car 1))")
            == "#t\n#f\n2\n3\n#f\n4\n");
    assert(run("(if 0 'yes 'no) (if '() 'yes 'no) (if \"\" 'yes 'no) (if #f 1 2)")
            == "yes\nyes\nyes\n2\n");
    assert(run("(cond ((begin (display 1) #f) 0) ((begin (display 2) 'x)))") == "12x\n");
}

unittest // data and equivalence
{
    assert(run("(list) (list 1 (list 2 3)) '(1 . 2) '(1 2 . 3) ''a '()")
            == "()\n(1 (2 3))\n(1 . 2)\n(1 2 . 3)\n(quote a)\n()\n");
    assert(run("(eq? 'a 'a) (eq? '() '()) (eq? (list 1) (list 1)) (equal? (list 1 \"s\") (list 1 \"s\")) (eq? 100000000000000000000 100000000000000000000)")
            == "#t\n#t\n#f\n#t\n#t\n");
    assert(run("(null? '()) (pair? '()) (pair? '(1)) (not #f) (not 0)") == "#t\n#f\n#t\n#t\n#f\n");
    assert(run("(number? 1) (string? \"\") (symbol? 'a) (boolean? #f) (procedure? car) (procedure? (lambda () 1)) (procedure? 'car)")
            == "#t\n#t\n#t\n#t\n#t\n#t\n#f\n");
    assert(run(`(string-append) (string-append "ab" "cd") (string-length "hello") (number->string -42) (symbol->string 'abc)`)
            == "\"\"\n\"abcd\"\n5\n\"-42\"\n\"abc\"\n");
}

unittest // apply
{
    assert(run("(apply + 1 2 '(3 4)) (apply list '()) (apply + '())") == "10\n()\n0\n");
    assert(run("(apply car '(1 2))") == "error: arity-error\n");
    assert(run("(apply + 1 2)") == "error: type-error\n");
    assert(run("(apply + 1 '(2 . 3))") == "error: type-error\n");
    assert(run("(apply +)") == "error: arity-error\n");
}

unittest // error categories
{
    assert(run("undefined") == "error: unbound-variable\n");
    assert(run("(car '())") == "error: type-error\n");
    assert(run("(+ 1 \"a\")") == "error: type-error\n");
    assert(run("(< 2 1 \"x\")") == "error: type-error\n");
    assert(run("(string-length 5)") == "error: type-error\n");
    assert(run("(5 5)") == "error: type-error\n");
    assert(run("((lambda (x) x))") == "error: arity-error\n");
    assert(run("((lambda (x) x) 1 2)") == "error: arity-error\n");
    assert(run("((lambda (a b . r) a) 1)") == "error: arity-error\n");
    assert(run("(car)") == "error: arity-error\n");
    assert(run("(cons 1)") == "error: arity-error\n");
    assert(run("(-)") == "error: arity-error\n");
    assert(run("(= 1)") == "error: arity-error\n");
    assert(run("(quotient 1 0)") == "error: division-by-zero\n");
    assert(run("(remainder 1 0)") == "error: division-by-zero\n");
    assert(run("(error 'a \"b\" 3)") == "error: user-error\n");
    assert(run("(error)") == "error: user-error\n");
    // output so far is kept and the error line follows directly
    assert(run("(display \"abc\") (car 1) (display \"never\")") == "abcerror: type-error\n");
}

unittest // tail calls run in constant host stack
{
    assert(run(`(define (loop i) (if (= i 0) 'done (loop (- i 1)))) (loop 1000000)`) == "done\n");
    assert(run(`(define (loop i) (cond ((= i 0) 'done) (else (loop (- i 1))))) (loop 1000000)`) == "done\n");
    assert(run(`(define (loop i) (or (= i 0) (loop (- i 1)))) (loop 1000000)`) == "#t\n");
    assert(run(`(define (loop i) (and (> i -1) (or (= i 0) (loop (- i 1))))) (loop 1000000)`) == "#t\n");
    assert(run(`(define (loop i) (if (= i 0) 'done (apply loop (list (- i 1))))) (loop 1000000)`) == "done\n");
    assert(run(`(define (loop i) (begin 1 (let ((j i)) (let* ((k j)) (letrec ((m k)) (if (= m 0) 'done (loop (- m 1)))))))) (loop 300000)`) == "done\n");
    assert(run(`(let loop ((i 0)) (if (< i 2000000) (loop (+ i 1)) i))`) == "2000000\n");
}

unittest // deep non-tail recursion
{
    string got;
    withLargeStack({
        got = run(`(define (f n) (if (= n 0) 0 (+ 1 (f (- n 1))))) (f 10000)`);
    });
    assert(got == "10000\n");
}

unittest // library API: persistence, eval, globals, sinks
{
    auto interp = new Interpreter;
    interp.run("(define x 20)");
    interp.run("(display (+ x 1))");
    assert(interp.takeOutput() == "21");
    auto v = interp.eval("(* x 2)");
    assert(v.kind == Kind.integer && v.i == 40);
    assert(toWriteString(interp.global("x")) == "20");

    bool threw;
    try
        interp.eval("(car 1)");
    catch (SchemeError e)
        threw = e.kind == ErrorKind.typeError;
    assert(threw);

    string collected;
    auto streaming = new Interpreter((const(char)[] c) { collected ~= c; });
    auto r = streaming.run("(display 1) (undefined)");
    assert(!r.ok && r.error == ErrorKind.unboundVariable);
    assert(collected == "1error: unbound-variable\n");
}

unittest // reader edge cases
{
    assert(run("(quote (a . (b . (c))))") == "(a b c)\n");
    assert(run("'(a;c\n b)") == "(a b)\n");
    assert(run("(define (f) 1)(f)(f)") == "1\n1\n");
    assert(run("'(1 . 2)") == "(1 . 2)\n");
    assert(run("'(+ - ... set! list->string <= a.b 1+)") == "(+ - ... set! list->string <= a.b 1+)\n");
    assert(run("'Foo 'foo (eq? 'Foo 'foo)") == "Foo\nfoo\n#f\n");
}
