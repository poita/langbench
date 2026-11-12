import pytest

from scheme_interp import Interpreter, SchemeError, run_program


def test_spec_example_1(run):
    src = """
(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
(fact 20)
(display "done") (newline)
'(1 "two" (3 . 4) #t)
(cons 1 2)
"""
    assert run(src) == '2432902008176640000\ndone\n(1 "two" (3 . 4) #t)\n(1 . 2)\n'


def test_spec_example_2(run):
    src = """
(define (make-counter) (let ((n 0)) (lambda () (set! n (+ n 1)) n)))
(define c (make-counter))
(c) (c)
(let loop ((i 0) (acc 0)) (if (= i 1000000) acc (loop (+ i 1) (+ acc i))))
(map (lambda (x) (* x x)) '(1 2 3))
"""
    assert run(src) == "1\n2\n499999500000\nerror: unbound-variable\n"


def test_spec_example_3(run):
    src = """
(display "a") (display (list 1 "b" 'c)) (newline)
(if #f #f)
(list (if #f #f) car)
(quotient 1 0)
(display "never")
"""
    out = run(src)
    assert out == "a(1 b c)\n(#<void> #<procedure>)\nerror: division-by-zero\n"


@pytest.mark.parametrize(
    "src, category",
    [
        ("undefined-var", "unbound-variable"),
        ("(set! nope 1)", "unbound-variable"),
        ("(car '())", "type-error"),
        ("(+ 1 \"x\")", "type-error"),
        ("(< 2 1 \"x\")", "type-error"),
        ("(5 5)", "type-error"),
        ("(apply + 1 2)", "type-error"),
        ("((lambda (a b) a) 1)", "arity-error"),
        ("((lambda (a) a) 1 2)", "arity-error"),
        ("((lambda (a b . r) a) 1)", "arity-error"),
        ("(car)", "arity-error"),
        ("(cons 1)", "arity-error"),
        ("(-)", "arity-error"),
        ("(= 1)", "arity-error"),
        ("(quotient 1 0)", "division-by-zero"),
        ("(remainder 10 0)", "division-by-zero"),
        ("(error \"boom\" 1 2)", "user-error"),
    ],
)
def test_error_categories(run, src, category):
    assert run(src) == f"error: {category}\n"


def test_error_is_appended_directly_and_stops(run):
    assert run('(display "abc") (car 1) (display "never")') == "abcerror: type-error\n"
    assert run('(car (display "x") (display "y"))') == "xyerror: arity-error\n"
    assert run('(set! u (begin (display "v") 1))') == "verror: unbound-variable\n"


def test_evaluation_order(run):
    src = """
(define (show x) (display x) x)
(- (show 10) (show 3) (show 2))
((show car) (show (list (show 'deep))))
(let ((a (show 1)) (b (show 2))) (newline) (list a b))
"""
    assert run(src) == "10325\n#<procedure>deep(deep)deep\n12\n(1 2)\n"


def test_define_in_bodies_and_let_star_frames(run):
    assert run("(let* ((a 1) (f (lambda () a))) (define a 2) (list a (f)))") == "(2 1)\n"
    assert run("(let ((x 1)) (define y 2) (+ x y))") == "3\n"
    assert run("(define (f) (define a 1) (define (g) (* a 10)) (g)) (f)") == "10\n"


def test_named_let_scope(run):
    assert run("(define loop 5) (let loop ((x loop)) x)") == "5\n"
    assert run("(let go ((x 1)) (procedure? go))") == "#t\n"
    assert run("(let lp ((x 1)) (set! lp 'r) (list x lp))") == "(1 r)\n"


def test_letrec_mutual_recursion(run):
    src = """
(letrec ((ev? (lambda (n) (if (= n 0) #t (od? (- n 1)))))
         (od? (lambda (n) (if (= n 0) #f (ev? (- n 1))))))
  (ev? 101))
"""
    assert run(src) == "#f\n"


def test_cond_forms(run):
    assert run("(cond (#f 1))") == ""
    assert run("(cond (5))") == "5\n"
    assert run("(cond (#f 1) (else 2 3))") == "3\n"
    assert run("(list (and) (or) (and 1 2) (or #f 3))") == "(#t #f 2 3)\n"


def test_variadic_lambdas(run):
    assert run("((lambda args args) 1 2 3)") == "(1 2 3)\n"
    assert run("((lambda (a . r) (list a r)) 1 2 3)") == "(1 (2 3))\n"
    assert run("(define (f a . r) r) (f 1)") == "()\n"
    assert run("(apply + 1 2 '(3 4))") == "10\n"


def test_equivalence(run):
    assert run("(list (eq? 'a 'a) (eq? '() '()) (eq? (list 1) (list 1)) (eq? 100000000000000000000 100000000000000000000))") == "(#t #t #f #t)\n"
    assert run("(list (equal? '(1 (2 \"x\")) '(1 (2 \"x\"))) (equal? \"a\" \"b\") (equal? car car))") == "(#t #f #t)\n"


def test_truthiness(run):
    assert run("(list (if 0 1 2) (if '() 1 2) (if \"\" 1 2) (if #f 1 2))") == "(1 1 1 2)\n"


def test_strings_and_symbols(run):
    assert run('(string-append "a" "bc" "")') == '"abc"\n'
    assert run('(string-length "héllo")') == "5\n"
    assert run("(number->string -123)") == '"-123"\n'
    assert run("(symbol->string 'abc)") == '"abc"\n'
    assert run('(display "a\\"b") (write-nothing)') == 'a"berror: unbound-variable\n'


def test_arithmetic_signs(run):
    assert run("(list (quotient -7 2) (quotient 7 -2) (remainder -7 2) (remainder 7 -2))") == "(-3 -3 -1 1)\n"
    assert run("(list (+) (*) (- 5) (- 10 1 2 3))") == "(0 1 -5 4)\n"
    assert run("(list (< 1 2 3) (< 1 3 2) (= 2 2 2) (>= 3 3 1) (<= 1 1 0))") == "(#t #f #t #t #f)\n"


def test_bignum_arithmetic_end_to_end(run):
    assert run("(* 4611686018427387904 4611686018427387904)") == "21267647932558653966460912964485513216\n"
    assert run("(- (* 99999999999 99999999999 99999999999) (* 99999999999 99999999999 99999999998))") == "9999999999800000000001\n"
    assert run("(quotient (* 123456789012345678901234567890 1000000007) 1000000007)") == "123456789012345678901234567890\n"
    assert run("(remainder (+ (* 10000000000000000000000 7) 3) 10000000000000000000000)") == "3\n"
    assert run("(= (* 3037000500 3037000500) 9223372037000250000)") == "#t\n"


def test_factorial_2000_digits(run):
    out = run("(define (f n) (if (= n 0) 1 (* n (f (- n 1))))) (f 2000)")
    assert len(out.strip()) == 5736


def test_tail_calls_run_in_constant_stack(run):
    src = """
(define (loop i) (if (= i 0) 'done (loop (- i 1))))
(loop 300000)
(define (loop2 i) (cond ((= i 0) 'done) (else (apply loop2 (list (- i 1))))))
(loop2 300000)
(define (loop3 i) (or (= i 0) (loop3 (- i 1))))
(loop3 300000)
(let lp ((i 300000)) (and #t (if (= i 0) 'ok (lp (- i 1)))))
(define (loop4 i) (let* ((j i)) (letrec ((k j)) (begin (if (= k 0) 'end (loop4 (- k 1)))))))
(loop4 300000)
"""
    assert run(src) == "done\ndone\n#t\nok\nend\n"


def test_deep_non_tail_recursion(run):
    src = "(define (count n) (if (= n 0) 0 (+ 1 (count (- n 1))))) (count 10000)"
    assert run(src) == "10000\n"


def test_interpreter_keeps_globals_between_runs():
    interp = Interpreter()
    assert interp.run("(define x 10)") == ""
    assert interp.run("(* x x)") == "100\n"


def test_independent_interpreters_have_independent_globals():
    a, b = Interpreter(), Interpreter()
    a.run("(define z 1)")
    assert b.run("z") == "error: unbound-variable\n"


def test_eval_forms_raises_scheme_error():
    with pytest.raises(SchemeError) as info:
        list(Interpreter().eval_forms("(car 5)"))
    assert info.value.category == "type-error"


def test_empty_program(run):
    assert run("") == ""
    assert run("; only a comment") == ""


def test_write_form_of_values(run):
    assert run("(list car (lambda (x) x) (if #f #f))") == "(#<procedure> #<procedure> #<void>)\n"
    assert run("'(a . (b . (c)))") == "(a b c)\n"
    assert run('(list "a\\nb\\t\\\\")') == '("a\\nb\\t\\\\")\n'
