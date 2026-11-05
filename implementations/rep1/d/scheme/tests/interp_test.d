/// Unit tests for the interpreter end to end.
module interp_test;

import scheme;

private string run(string src)
{
    return runProgram(src);
}

unittest // spec examples
{
    assert(run(`(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
(fact 20)
(display "done") (newline)
'(1 "two" (3 . 4) #t)
(cons 1 2)`) == "2432902008176640000\ndone\n(1 \"two\" (3 . 4) #t)\n(1 . 2)\n");

    assert(run(`(define (make-counter)
  (let ((n 0)) (lambda () (set! n (+ n 1)) n)))
(define c (make-counter))
(c) (c)
(let loop ((i 0) (acc 0))
  (if (= i 1000000) acc (loop (+ i 1) (+ acc i))))
(map (lambda (x) (* x x)) '(1 2 3))`)
            == "1\n2\n499999500000\nerror: unbound-variable\n");

    assert(run(`(display "a") (display (list 1 "b" 'c)) (newline)
(if #f #f)
(list (if #f #f) car)
(quotient 1 0)
(display "never")`) == "a(1 b c)\n(#<void> #<procedure>)\nerror: division-by-zero\n");
}

unittest // arithmetic and promotion
{
    assert(run("(+ 9223372036854775807 1)") == "9223372036854775808\n");
    assert(run("(- -9223372036854775808)") == "9223372036854775808\n");
    assert(run("(- -9223372036854775808 1)") == "-9223372036854775809\n");
    assert(run("(* 4294967296 4294967296)") == "18446744073709551616\n");
    assert(run("(- (+ 9223372036854775807 1) 1)") == "9223372036854775807\n");
    assert(run("(quotient -9223372036854775808 -1)") == "9223372036854775808\n");
    assert(run("(remainder -9223372036854775808 -1)") == "0\n");
    assert(run("(quotient -7 2) (quotient 7 -2) (remainder -7 2) (remainder 7 -2)")
            == "-3\n-3\n-1\n1\n");
    assert(run("(< 1 2 3) (< 1 3 2) (= 2 2 2) (>= 3 3 1)") == "#t\n#f\n#t\n#t\n");
    assert(run("(eq? 100000000000000000000 100000000000000000000)") == "#t\n");
    assert(run("(+) (*)") == "0\n1\n");
}

unittest // factorial 25
{
    assert(run(`(define (f n) (if (= n 0) 1 (* n (f (- n 1))))) (f 25)
(quotient (f 25) (f 23)) (remainder (f 25) 1000007) (number->string (f 25))`)
            == "15511210043330985984000000\n600\n"
            ~ "913534\n\"15511210043330985984000000\"\n");
}

unittest // errors
{
    assert(run("(display \"x\") (car 1)") == "xerror: type-error\n");
    assert(run("(< 2 1 \"x\")") == "error: type-error\n");
    assert(run("(car (display \"x\") (display \"y\"))") == "xyerror: arity-error\n");
    assert(run("((lambda (x) x))") == "error: arity-error\n");
    assert(run("(5 (display \"a\"))") == "aerror: type-error\n");
    assert(run("(set! zz (display \"v\"))") == "verror: unbound-variable\n");
    assert(run("(error 1 2 3) (display 1)") == "error: user-error\n");
    assert(run("(apply + '(1 . 2))") == "error: type-error\n");
}

unittest // tail calls and deep recursion
{
    assert(run("(define (loop n) (if (= n 0) 'done (loop (- n 1)))) (loop 300000)")
            == "done\n");
    assert(run("(define (count n) (if (= n 0) 0 (+ 1 (count (- n 1))))) (count 10000)")
            == "10000\n");
    assert(run("(define (f n) (cond ((= n 0) 'ok) (else (apply f (list (- n 1)))))) (f 100000)")
            == "ok\n");
}

unittest // scoping rules
{
    assert(run("(let* ((a 1) (f (lambda () a))) (define a 2) (list a (f)))") == "(2 1)\n");
    assert(run("(define loop 5) (let loop ((x loop)) x)") == "5\n");
    assert(run("(define (f . r) r) (f 1 2) (f)") == "(1 2)\n()\n");
    assert(run("((lambda (a b . r) (list a b r)) 1 2 3 4)") == "(1 2 (3 4))\n");
    assert(run("(define (f) (define x 1) (define y (+ x 1)) (list x y)) (f)") == "(1 2)\n");
    assert(run("(letrec ((ev? (lambda (n) (if (= n 0) #t (od? (- n 1)))))"
            ~ " (od? (lambda (n) (if (= n 0) #f (ev? (- n 1)))))) (ev? 10))") == "#t\n");
}

unittest // equality and printing
{
    assert(run("(equal? '(1 (2 \"a\")) '(1 (2 \"a\"))) (eq? '(1) '(1)) (eq? 'a 'a)")
            == "#t\n#f\n#t\n");
    assert(run("''a") == "(quote a)\n");
    assert(run(`(display '("x" y)) (write-me)`) == "(x y)error: unbound-variable\n");
    assert(run(`"a\"b"`) == "\"a\\\"b\"\n");
    assert(run("(cond (#f 1)) (cond (5))") == "5\n");
    assert(run("(string-append \"ab\" \"cd\") (string-length \"abc\") (symbol->string 'foo)")
            == "\"abcd\"\n3\n\"foo\"\n");
}

unittest // interpreter keeps state between run calls
{
    auto i = new Interpreter;
    assert(i.run("(define x 41)") == "");
    assert(i.run("(+ x 1)") == "42\n");
}
