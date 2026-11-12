//! End-to-end tests of the language through the public library API.

/// Runs a program on a thread with a large stack: unoptimised test builds use
/// much more host stack per Scheme call than the release binary does.
fn run(src: &str) -> String {
    let src = src.to_string();
    std::thread::Builder::new()
        .stack_size(512 << 20)
        .spawn(move || scheme::run_to_string(&src))
        .unwrap()
        .join()
        .unwrap()
}

#[test]
fn spec_example_1() {
    let src = "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
(fact 20)
(display \"done\") (newline)
'(1 \"two\" (3 . 4) #t)
(cons 1 2)";
    assert_eq!(run(src), "2432902008176640000\ndone\n(1 \"two\" (3 . 4) #t)\n(1 . 2)\n");
}

#[test]
fn spec_example_2_stops_at_unbound_map() {
    let src = "(define (make-counter)
  (let ((n 0))
    (lambda () (set! n (+ n 1)) n)))
(define c (make-counter))
(c) (c)
(let loop ((i 0) (acc 0))
  (if (= i 1000000) acc (loop (+ i 1) (+ acc i))))
(map (lambda (x) (* x x)) '(1 2 3))";
    assert_eq!(run(src), "1\n2\n499999500000\nerror: unbound-variable\n");
}

#[test]
fn spec_example_3() {
    let src = "(display \"a\")
(display (list 1 \"b\" 'c))
(newline)
(if #f #f)
(list (if #f #f) car)
(quotient 1 0)
(display \"never\")";
    assert_eq!(run(src), "a(1 b c)\n(#<void> #<procedure>)\nerror: division-by-zero\n");
}

#[test]
fn empty_program_and_comments() {
    assert_eq!(run(""), "");
    assert_eq!(run("; nothing\n  ; here"), "");
}

#[test]
fn error_is_appended_without_newline() {
    assert_eq!(run("(display \"x\") (car 1)"), "xerror: type-error\n");
}

#[test]
fn error_categories() {
    assert_eq!(run("foo"), "error: unbound-variable\n");
    assert_eq!(run("(set! foo 1)"), "error: unbound-variable\n");
    assert_eq!(run("(car '())"), "error: type-error\n");
    assert_eq!(run("(< 2 1 \"x\")"), "error: type-error\n");
    assert_eq!(run("(5 1)"), "error: type-error\n");
    assert_eq!(run("(apply + 1 2)"), "error: type-error\n");
    assert_eq!(run("((lambda (x) x))"), "error: arity-error\n");
    assert_eq!(run("((lambda (x) x) 1 2)"), "error: arity-error\n");
    assert_eq!(run("(car)"), "error: arity-error\n");
    assert_eq!(run("(remainder 1 0)"), "error: division-by-zero\n");
    assert_eq!(run("(error 'a \"b\")"), "error: user-error\n");
}

#[test]
fn arguments_are_evaluated_before_arity_check() {
    assert_eq!(run("(car (display \"x\") (display \"y\"))"), "xyerror: arity-error\n");
}

#[test]
fn evaluation_order_is_left_to_right() {
    let src = "(define (t x) (display x) x)
(list (t 1) (t 2) (t 3))
(let ((a (t 4)) (b (t 5))) (+ a b))
(and (t 6) (t #f) (t 7))
(cond ((t #f) 1) ((t 8) 2))";
    assert_eq!(run(src), "123(1 2 3)\n459\n6#f#f\n#f82\n");
}

#[test]
fn write_and_display_forms() {
    assert_eq!(run("\"a\\\"b\\\\c\\nd\\te\""), "\"a\\\"b\\\\c\\nd\\te\"\n");
    assert_eq!(run("(display '(\"x\" y (\"z\")))"), "(x y (z))");
    assert_eq!(run("''a"), "(quote a)\n");
    assert_eq!(run("'(1 (2 . 3) ())"), "(1 (2 . 3) ())\n");
}

#[test]
fn define_scoping() {
    let src = "(define (f) (define x 1) (define (g) x) (g))
(f)
(define x 10)
(let ((y 1)) (define x 2) x)
x
(let* ((a 1) (g (lambda () a))) (define a 5) (list a (g)))";
    assert_eq!(run(src), "1\n2\n10\n(5 1)\n");
}

#[test]
fn named_let_scope() {
    let src = "(define loop 'outer)
(let loop ((i 0) (init loop)) (if (< i 1) (loop (+ i 1) init) init))
(let loop ((i 0)) (if (< i 3) (loop (+ i 1)) (procedure? loop)))";
    assert_eq!(run(src), "outer\n#t\n");
}

#[test]
fn variadic_lambdas() {
    let src = "((lambda args args) 1 2 3)
((lambda (a . rest) rest) 1)
((lambda (a b . rest) rest) 1 2 3 4)
(apply (lambda (a b . r) (list a b r)) 1 '(2 3))";
    assert_eq!(run(src), "(1 2 3)\n()\n(3 4)\n(1 2 (3))\n");
}

#[test]
fn letrec_mutual_recursion() {
    let src = "(letrec ((even? (lambda (n) (if (= n 0) #t (odd? (- n 1)))))
         (odd? (lambda (n) (if (= n 0) #f (even? (- n 1))))))
  (even? 1001))";
    assert_eq!(run(src), "#f\n");
}

#[test]
fn eq_and_equal() {
    let src = "(eq? 'a 'a) (eq? 100000000000000000000 100000000000000000000)
(eq? (list 1) (list 1)) (equal? (list 1 \"a\") (list 1 \"a\"))
(eq? '() '()) (eq? car car) (equal? 1 'a)";
    assert_eq!(run(src), "#t\n#t\n#f\n#t\n#t\n#t\n#f\n");
}

#[test]
fn cond_forms() {
    assert_eq!(run("(cond (#f 1))"), "");
    assert_eq!(run("(cond (5)) (cond (#f 1) (else 2 3))"), "5\n3\n");
}

#[test]
fn bignum_arithmetic() {
    let src = "(* 99999999999999999999 99999999999999999999)
(- (* 4611686018427387904 2))
(quotient (* 123456789012345678901234567890 1000000007) 1000000007)
(remainder -100000000000000000007 1000)
(quotient -100000000000000000007 1000)
(+ 9223372036854775807 1)
(- -9223372036854775808 1)
(< 100000000000000000000 100000000000000000001 200000000000000000000)
(number->string -100000000000000000000)";
    assert_eq!(
        run(src),
        "9999999999999999999800000000000000000001\n-9223372036854775808\n123456789012345678901234567890\n-7\n-100000000000000000\n9223372036854775808\n-9223372036854775809\n#t\n\"-100000000000000000000\"\n"
    );
}

#[test]
fn factorial_2000_has_5736_digits() {
    let out = run("(define (f n) (if (= n 0) 1 (* n (f (- n 1))))) (number->string (f 2000))");
    assert_eq!(out.trim().len(), 5736 + 2);
}

#[test]
fn strings_and_symbols() {
    let src = "(string-append \"ab\" \"cd\") (string-append) (string-length \"hello\")
(symbol->string 'foo) (number->string 42)";
    assert_eq!(run(src), "\"abcd\"\n\"\"\n5\n\"foo\"\n\"42\"\n");
}

#[test]
fn tail_calls_run_in_constant_stack() {
    let src = "(define (count n) (if (= n 0) 'done (count (- n 1)))) (count 3000000)
(define (via-apply n) (if (= n 0) 'ok (apply via-apply (list (- n 1))))) (via-apply 1000000)
(define (via-or n) (or (= n 0) (via-or (- n 1)))) (via-or 1000000)
(define (via-cond n) (cond ((= n 0) 'c) (else (via-cond (- n 1))))) (via-cond 1000000)
(define (via-and n) (and #t (if (= n 0) 'a (via-and (- n 1))))) (via-and 200000)
(define (via-begin n) (begin 1 (if (= n 0) 'b (via-begin (- n 1))))) (via-begin 200000)";
    assert_eq!(run(src), "done\nok\n#t\nc\na\nb\n");
}

#[test]
fn deep_non_tail_recursion() {
    let out = run("(define (sum n) (if (= n 0) 0 (+ n (sum (- n 1))))) (sum 10000)");
    assert_eq!(out, "50005000\n");
}

#[test]
fn long_lists_drop_without_overflow() {
    let src = "(define (build n acc) (if (= n 0) acc (build (- n 1) (cons n acc))))
(define l (build 500000 '()))
(car l)";
    assert_eq!(run(src), "1\n");
}
