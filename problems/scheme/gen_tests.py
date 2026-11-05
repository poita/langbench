#!/usr/bin/env python3
"""Generates tests/*.in and tests/*.out for the `scheme` problem.

Hand-written programs carry a hand-written expected output; seeded random
programs carry an expected output computed by small independent Python
oracles (integer arithmetic with truncating division, a datum printer, a
straight-line program evaluator). Every expected output is asserted against
reference/main.py before the .out file is written, so a disagreement between
the reference and the oracle aborts generation instead of producing a wrong
suite.
"""
import math
import os
import random
import subprocess
import sys

sys.set_int_max_str_digits(0)

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, 'tests')
REF = os.path.join(HERE, 'reference', 'main.py')

cases = []


def add(name, program, expected):
    """expected: list of output lines (without newlines), or None to accept
    whatever the reference prints (used only where noted)."""
    cases.append((name, program, expected))


# ---------------------------------------------------------------------------
# Hand-written tests: syntax, printing, special forms, primitives
# ---------------------------------------------------------------------------

add('empty_program', '', [])

add('comments_only', '''; a comment
;; another comment (with parens) and "quotes"
   ; indented
''', [])

add('literals', '''42
-7
+5
007
0
-0
#t
#f
"hello"
"a\\"b\\\\c\\nd\\te"
"multi
line"
123456789012345678901234567890
'sym
'Foo
'()
1;comment right after
2 ; comment with spaces
"str;not a comment"
''', ['42', '-7', '5', '7', '0', '0', '#t', '#f', '"hello"', '"a\\"b\\\\c\\nd\\te"',
      '"multi\\nline"', '123456789012345678901234567890', 'sym', 'Foo', '()',
      '1', '2', '"str;not a comment"'])

add('arithmetic', '''(+) (+ 5) (+ 1 2 3 4) (*) (* 7) (* 2 3 4) (- 5) (- 10 3) (- 10 1 2 3) (- -5)
(quotient 7 2) (quotient -7 2) (quotient 7 -2) (quotient -7 -2)
(remainder 7 2) (remainder -7 2) (remainder 7 -2) (remainder -7 -2)
(quotient 0 5) (remainder 0 5) (quotient 5 7) (remainder 5 7)
(* 99999999999 99999999999) (- 0 99999999999999999999) (+ 99999999999999999999 1)
(quotient 100000000000000000000 3) (remainder 100000000000000000000 3)
(+ (* 2 3) (- 10 4) (quotient 9 2))
(quotient 1 1) (remainder -1 1) (quotient -1 -1) (quotient 6 -3) (remainder 6 -3)
''', ['0', '5', '10', '1', '7', '24', '-5', '7', '4', '5',
      '3', '-3', '-3', '3',
      '1', '-1', '1', '-1',
      '0', '0', '0', '5',
      '9999999999800000000001', '-99999999999999999999', '100000000000000000000',
      '33333333333333333333', '1',
      '16',
      '1', '0', '1', '-2', '0'])

add('comparisons', '''(= 1 1) (= 1 2) (= 1 1 1) (= 1 1 2)
(< 1 2) (< 2 1) (< 1 2 3) (< 1 3 2) (< 1 1)
(> 3 2 1) (> 3 1 2) (<= 1 1 2) (<= 1 2 1) (>= 3 3 1) (>= 3 4)
(< -1 0 1) (= 100000000000000000000 100000000000000000000) (< 99999999999999999999 100000000000000000000)
(not #t) (not #f) (not 0) (not '()) (not "")
(= 0 -0)
(> 1 2 "not checked?")
''', ['#t', '#f', '#t', '#f',
      '#t', '#f', '#t', '#f', '#f',
      '#t', '#f', '#t', '#f', '#t', '#f',
      '#t', '#t', '#t',
      '#f', '#t', '#f', '#f', '#f',
      '#t',
      'error: type-error'])

add('quote_printing', """'a
'(1 2 3)
'(1 . 2)
'(1 2 . 3)
'((1 2) (3 . 4) ())
'(a "b" #t #f 5 -5)
''a
'(quote a)
'(quote)
'(quote a b)
'(1 . (2 . (3 . ())))
'(1 . (2 . 3))
'(() ())
'((()))
'(#t . #f)
(quote (quote (quote x)))
'(define (f x) (+ x 1))
'|weird|
'set!
'...
'("a\\"b" "c\\\\d" "e\\nf")
(quote 5)
(quote "s")
'(   spaced   out  )
'(a
  b ; comment inside
  c)
""", ['a', '(1 2 3)', '(1 . 2)', '(1 2 . 3)', '((1 2) (3 . 4) ())', '(a "b" #t #f 5 -5)',
      '(quote a)', '(quote a)', '(quote)', '(quote a b)', '(1 2 3)', '(1 2 . 3)', '(() ())',
      '((()))', '(#t . #f)', '(quote (quote x))', '(define (f x) (+ x 1))', '|weird|', 'set!',
      '...', '("a\\"b" "c\\\\d" "e\\nf")', '5', '"s"', '(spaced out)', '(a b c)'])

add('strings', '''(string-append) (string-append "a") (string-append "a" "b" "c") (string-append "" "" "")
(string-length "") (string-length "hello") (string-length "a\\"b\\\\c\\nd\\te")
(number->string 0) (number->string -42) (number->string 123456789012345678901234567890)
(symbol->string 'hello) (symbol->string 'a-b?) (string-length (symbol->string 'abc))
(string-append (number->string 12) (symbol->string 'x) "!")
(string? "x") (string? 'x) (symbol? 'x) (symbol? "x")
(equal? "abc" "abc") (equal? "abc" "abd") (equal? "abc" 'abc) (equal? "" "")
"tab\\there" "quote\\"q" "back\\\\slash" "new\\nline"
(display "tab\\there") (newline) (display "quote\\"q") (newline) (display "back\\\\slash") (newline) (display "new\\nline") (newline)
(string-length (string-append "abc" "defg"))
(number->string (string-length "four"))
''', ['""', '"a"', '"abc"', '""', '0', '5', '9', '"0"', '"-42"', '"123456789012345678901234567890"',
      '"hello"', '"a-b?"', '3', '"12x!"', '#t', '#f', '#t', '#f', '#t', '#f', '#f', '#t',
      '"tab\\there"', '"quote\\"q"', '"back\\\\slash"', '"new\\nline"',
      'tab\there', 'quote"q', 'back\\slash', 'new', 'line', '7', '"4"'])

add('display_newline', '''(display 42) (newline)
(display -7) (display " ") (display #t) (display " ") (display #f) (newline)
(display "str") (newline)
(display 'sym) (newline)
(display '()) (newline)
(display '(1 "two" three (4 . 5) ("six" ("seven")))) (newline)
(display (cons 1 2)) (newline)
(display car) (newline)
(display (lambda (x) x)) (newline)
(display (if #f #f)) (newline)
(display (list (if #f #f))) (newline)
(display "no newline between")
(display "these")
(newline)
(display 1) 2 (display 3) (newline)
(newline) (newline)
(display (display "inner")) (newline)
(display "end")''', ['42', '-7 #t #f', 'str', 'sym', '()', '(1 two three (4 . 5) (six (seven)))',
                     '(1 . 2)', '#<procedure>', '#<procedure>', '#<void>', '(#<void>)',
                     'no newline betweenthese', '12', '3', '', '', 'inner#<void>', 'end'])

add('define_set', '''(define x 10)
x
(define y (+ x 5))
y
(set! x 20)
x
(define x 30)
x
(define (get) x)
(get)
(set! x 40)
(get)
(define z (begin (set! x 50) x))
z
(define (shadow x) (set! x (+ x 1)) x)
(shadow 1)
x
(define (outer)
  (define a 1)
  (set! a (+ a 1))
  a)
(outer)
(define f (lambda () 'first))
(f)
(define f (lambda () 'second))
(f)
(begin (define w 7) (display w) (newline))
w
(define v (if #f #f))
(list v)
(define (setter) (set! x 'changed-inside))
(setter)
x
(list (set! x 1) (define q 2))
(list x q)
''', ['10', '15', '20', '30', '30', '40', '50', '2', '50', '2', 'first', 'second', '7', '7',
      '(#<void>)', 'changed-inside', '(#<void> #<void>)', '(1 2)'])

add('lambda_closures', '''((lambda (x) (* x x)) 7)
((lambda () 42))
(define (make-adder n) (lambda (x) (+ x n)))
(define add5 (make-adder 5))
(add5 10)
((make-adder 100) 1)
(define (make-counter)
  (let ((n 0))
    (lambda () (set! n (+ n 1)) n)))
(define c1 (make-counter))
(define c2 (make-counter))
(c1) (c1) (c1) (c2) (c1)
(define (compose f g) (lambda (x) (f (g x))))
((compose add5 add5) 0)
((compose (lambda (x) (* 2 x)) add5) 1)
(define (twice f) (compose f f))
(((twice twice) add5) 0)
(procedure? add5) (procedure? c1) (procedure? 5)
(lambda (x) x)
make-adder
car
(define (curry f a) (lambda (b) (f a b)))
((curry cons 1) 2)
((curry - 10) 3)
(let ((x 1)) (let ((f (lambda () x))) (let ((x 2)) (f))))
((lambda (x) (lambda (y) (+ x y))) 1)
(((lambda (x) (lambda (y) (+ x y))) 1) 2)
((lambda (f) (f f 5)) (lambda (self n) (if (= n 0) 1 (* n (self self (- n 1))))))
''', ['49', '42', '15', '101', '1', '2', '3', '1', '4', '10', '12', '20', '#t', '#t', '#f',
      '#<procedure>', '#<procedure>', '#<procedure>', '(1 . 2)', '7', '1', '#<procedure>', '3',
      '120'])

add('let_forms', """(let ((x 1) (y 2)) (+ x y))
(let ((x 1)) (let ((x 2) (y x)) (list x y)))
(let* ((x 1) (y (+ x 1)) (z (* y 2))) (list x y z))
(let* () 5)
(let () 6)
(letrec ((fact (lambda (n) (if (= n 0) 1 (* n (fact (- n 1))))))) (fact 10))
(letrec ((even? (lambda (n) (if (= n 0) #t (odd? (- n 1)))))
         (odd? (lambda (n) (if (= n 0) #f (even? (- n 1))))))
  (list (even? 10) (odd? 10) (even? 7)))
(let loop ((i 0) (acc '()))
  (if (= i 5) acc (loop (+ i 1) (cons i acc))))
(let loop ((i 3))
  (display i)
  (if (> i 0) (loop (- i 1)) 'done))
(define x 100)
(let ((x 1) (y x)) (list x y))
(let* ((x 1) (y x)) (list x y))
(let ((x 5)) (define y (* x 2)) (+ x y))
x
(let ((f (lambda (n) (* n n)))) (f 9))
(let ((lst '(1 2 3))) (let loop ((l lst) (s 0)) (if (null? l) s (loop (cdr l) (+ s (car l))))))
(letrec ((a 1) (b (+ a 1))) (list a b))
(let ((x 1))
  (let ((g (let ((x 2)) (lambda () x))))
    (g)))
(let loop ((n 3)) (if (= n 0) '() (cons n (loop (- n 1)))))
(let ((x 1)) (set! x 2) x)
x
(let* ((x 1) (x (+ x 1)) (x (* x 10))) x)
(let loop ((i 0)) (if (< i 3) (begin (display i) (loop (+ i 1)))))
(newline)
(let ((loop 'shadowed)) (let loop ((i 2)) (if (= i 0) 'ok (loop (- i 1)))))
(let () (define a 1) (define b 2) (+ a b))
""", ['3', '(2 1)', '(1 2 4)', '5', '6', '3628800', '(#t #f #f)', '(4 3 2 1 0)', '3210done',
      '(1 100)', '(1 1)', '15', '100', '81', '6', '(1 2)', '2', '(3 2 1)', '2', '100', '20',
      '012', 'ok', '3'])

add('named_let_scope', """(define loop 5)
(let loop ((x loop)) x)
(let loop ((i 2) (j (list 'j))) (if (= i 0) j (loop (- i 1) (cons i j))))
loop
(let lp ((lp2 (procedure? 'lp))) lp2)
(define (uses-outer-name)
  (let lp ((n 3) (acc '()))
    (if (= n 0) acc (lp (- n 1) (cons n acc)))))
(uses-outer-name)
(let iter ((k (let iter ((m 3)) (if (= m 0) 'inner-done (iter (- m 1)))))) k)
(let go ((x 1)) (procedure? go))
(let lp ((x 1)) (set! lp 'rebound) (list x lp))
(let f ((l (lambda () 'outer)))
  (if (eq? (l) 'outer) (f (lambda () 'inner)) (l)))
(let lp ((i 0)) (if (< i 3) (lp (+ i 1)) i))
lp
""", ['5', '(1 2 j)', '5', '#f', '(1 2 3)', 'inner-done', '#t', '(1 rebound)', 'inner', '3',
      'error: unbound-variable'])

add('let_star_frames', """(let* ((a 1) (f (lambda () a))) (define a 2) (list a (f)))
(let* ((a 1) (f (lambda () a))) (set! a 2) (list a (f)))
(let* ((a 1) (a (+ a 1)) (f (lambda () a)) (a (* a 10))) (list a (f)))
(let* ((x 1) (y (+ x 1))) (define x 100) (list x y))
(let* ((g (lambda () b)) (b 2)) (define b 3) (list b (g)))
""", ['(2 1)', '(2 2)', '(20 2)', '(100 2)', 'error: unbound-variable'])

add('cond_and_or', '''(cond (#t 1))
(cond (#f 1) (else 2))
(cond ((= 1 2) 'a) ((= 1 1) 'b) (else 'c))
(cond ((= 1 2) 'a) ((= 1 3) 'b) (else 'c))
(cond (#f 1))
(list (cond (#f 1)))
(cond (5))
(cond (#f) (7))
(cond ((+ 1 1) (display "x") (display "y") 'z))
(cond (else 1 2 3))
(define (classify n) (cond ((< n 0) 'negative) ((= n 0) 'zero) (else 'positive)))
(list (classify -5) (classify 0) (classify 5))
(and)
(or)
(and 1)
(or 1)
(and 1 2 3)
(or 1 2 3)
(and 1 #f 3)
(or #f #f 3)
(and #f (display "not printed"))
(or 1 (display "not printed"))
(and 1 (display "printed") 2)
(newline)
(or #f (display "printed2") 2)
(newline)
(and '() 0 "")
(or #f '())
(and (= 1 1) (< 1 2) 'yes)
(or (= 1 2) (< 2 1) 'fallback)
(if 0 'true 'false)
(if '() 'true 'false)
(if "" 'true 'false)
(if #f 'true 'false)
(if (not #f) 'true 'false)
(if #f 'true)
(list (if #f 'x))
(cond ((cond (#f 1)) 'void-is-true) (else 'unreachable))
(cond ('() 'empty-list-is-true))
(and 1 2 (or #f 3 4))
''', ['1', '2', 'b', 'c', '(#<void>)', '5', '7', 'xyz', '3', '(negative zero positive)',
      '#t', '#f', '1', '1', '3', '1', '#f', '3', '#f', '1', 'printed2', '', 'printed2',
      '""', '()', 'yes', 'fallback', 'true', 'true', 'true', 'false', 'true', '(#<void>)',
      'void-is-true', 'empty-list-is-true', '3'])

add('list_ops', """(cons 1 2)
(cons 1 '())
(cons 1 (cons 2 (cons 3 '())))
(cons '(1 2) '(3 4))
(cons '() '())
(list)
(list 1)
(list 1 2 3)
(list 1 "a" 'b #t '(c) (list))
(car '(1 2 3))
(cdr '(1 2 3))
(car (cdr (cdr '(1 2 3))))
(cdr '(1))
(car '((a b) c))
(cdr '(1 . 2))
(null? '())
(null? '(1))
(null? 0)
(null? #f)
(pair? '())
(pair? '(1))
(pair? (cons 1 2))
(pair? 5)
(define (length l) (if (null? l) 0 (+ 1 (length (cdr l)))))
(length '())
(length '(1 2 3 4 5))
(define (append a b) (if (null? a) b (cons (car a) (append (cdr a) b))))
(append '(1 2) '(3 4))
(append '() '(1))
(append '(1) '())
(define (reverse l) (let loop ((l l) (r '())) (if (null? l) r (loop (cdr l) (cons (car l) r)))))
(reverse '(1 2 3))
(reverse '())
(define (list-tail l k) (if (= k 0) l (list-tail (cdr l) (- k 1))))
(list-tail '(1 2 3 4) 2)
(define (list-ref l k) (car (list-tail l k)))
(list-ref '(a b c d) 3)
(let ((p (cons 1 2))) (list (car p) (cdr p) p))
(cons (cons 1 2) (cons 3 4))
(list 'quote 'a)
(list 'a 'quote)
(cons 1 (list 2 3))
(cons (list 1 2) 3)
(car (list car))
(cdr (cdr (cdr '(1 2 3))))
""", ['(1 . 2)', '(1)', '(1 2 3)', '((1 2) 3 4)', '(())', '()', '(1)', '(1 2 3)',
      '(1 "a" b #t (c) ())', '1', '(2 3)', '3', '()', '(a b)', '2', '#t', '#f', '#f', '#f',
      '#f', '#t', '#t', '#f', '0', '5', '(1 2 3 4)', '(1)', '(1)', '(3 2 1)', '()', '(3 4)',
      'd', '(1 2 (1 . 2))', '((1 . 2) 3 . 4)', '(quote a)', '(a quote)', '(1 2 3)', '((1 2) . 3)',
      '#<procedure>', '()'])

add('equal_eq', """(equal? 1 1)
(equal? 1 2)
(equal? 'a 'a)
(equal? 'a 'b)
(equal? '() '())
(equal? '(1 2 3) '(1 2 3))
(equal? '(1 2 3) '(1 2 4))
(equal? '(1 2 3) '(1 2))
(equal? '(1 (2 (3 (4)))) '(1 (2 (3 (4)))))
(equal? '(1 (2 (3 (4)))) '(1 (2 (3 (5)))))
(equal? '(1 . 2) '(1 . 2))
(equal? '(1 . 2) '(1 2))
(equal? '("a" ("b" "c")) (list "a" (list "b" "c")))
(equal? '("a" ("b" "c")) (list "a" (list "b" "d")))
(equal? (list 1 (cons 2 3) "x" 'y #t) (list 1 (cons 2 3) "x" 'y #t))
(equal? "abc" "abc")
(equal? "abc" 'abc)
(equal? 1 "1")
(equal? #t #t)
(equal? #f '())
(equal? car car)
(equal? car cdr)
(equal? 100000000000000000000 100000000000000000000)
(equal? (list (if #f #f)) (list (if #f #f)))
(eq? 'a 'a)
(eq? '() '())
(eq? 3 3)
(eq? 100000000000000000000 100000000000000000000)
(eq? #t #t)
(eq? #f #f)
(eq? #t #f)
(eq? '(1) '(1))
(let ((l '(1))) (eq? l l))
(eq? car car)
(eq? (lambda (x) x) (lambda (x) x))
(let ((f (lambda (x) x))) (eq? f f))
(eq? 'a "a")
(eq? 1 #t)
(eq? (if #f #f) (if #f #f))
(eq? 0 #f)
(eq? '() #f)
(define (deep n) (if (= n 0) '() (list (deep (- n 1)))))
(equal? (deep 50) (deep 50))
(define (deep2 n) (if (= n 0) 'x (list (deep2 (- n 1)))))
(equal? (deep 50) (deep2 50))
(let ((p (cons 1 2))) (list (eq? p p) (equal? p (cons 1 2)) (eq? p (cons 1 2))))
(equal? (string-append "a" "b") "ab")
(equal? '(1 2 . 3) '(1 2 . 3))
(equal? '(1 2 . 3) '(1 2 3))
""", ['#t', '#f', '#t', '#f', '#t', '#t', '#f', '#f', '#t', '#f', '#t', '#f', '#t', '#f',
      '#t', '#t', '#f', '#f', '#t', '#f', '#t', '#f', '#t', '#t',
      '#t', '#t', '#t', '#t', '#t', '#t', '#f', '#f', '#t', '#t', '#f', '#t', '#f', '#f',
      '#t', '#f', '#f', '#t', '#f', '(#t #t #f)', '#t', '#t', '#f'])

add('apply', """(apply + '(1 2 3))
(apply + '())
(apply + 1 2 '(3 4))
(apply list '(1 2 3))
(apply list 1 '())
(apply list '())
(apply cons '(1 2))
(apply car '((1 2)))
(apply (lambda (a b . c) (list a b c)) '(1 2 3 4))
(apply (lambda args args) 1 2 '(3))
(define (sum . xs) (apply + xs))
(sum) (sum 1) (sum 1 2 3 4 5)
(define (max2 a b) (if (> a b) a b))
(apply max2 '(3 9))
(apply apply (list + (list 1 2)))
(define (count-down n) (if (= n 0) 'done (apply count-down (list (- n 1)))))
(count-down 200000)
(apply string-append '("a" "b" "c"))
(apply < '(1 2 3))
(apply < '(1 3 2))
(apply display '("via apply")) (newline)
(define (f . args) (apply + args))
(f 1 2 3)
(apply f '(4 5 6))
(apply (lambda () 'no-args) '())
(apply + 1 '(2 . 3))
""", ['6', '0', '10', '(1 2 3)', '(1)', '()', '(1 . 2)', '1', '(1 2 (3 4))', '(1 2 3)',
      '0', '1', '15', '9', '3', 'done', '"abc"', '#t', '#f', 'via apply', '6', '15', 'no-args',
      'error: type-error'])

add('eval_order', """((begin (display "op") car) (begin (display "-arg") '(1)))
(newline)
((begin (display "f") (lambda (a b c) (list a b c))) (begin (display "1") 1) (begin (display "2") 2) (begin (display "3") 3))
(newline)
(list (display "a") (display "b") (display "c"))
(newline)
(let ((x (display "x")) (y (display "y")) (z (display "z"))) (newline) (list x y z))
(let* ((x (display "1")) (y (display "2"))) (newline) 'ok)
(letrec ((x (display "1")) (y (display "2"))) (newline) 'ok)
(let lp ((a (display "a")) (b (display "b"))) (newline) 'ok)
(cond ((begin (display "t1") #f) 'no) ((begin (display "t2") #f) 'no) ((begin (display "t3") 'yes)))
(newline)
(and (begin (display "1") 1) (begin (display "2") 2) (begin (display "3") #f) (begin (display "4") 4))
(newline)
(or (begin (display "1") #f) (begin (display "2") #f) (begin (display "3") 3) (begin (display "4") 4))
(newline)
(define d (begin (display "define-value") 'd))
(newline)
(set! d (begin (display "set-value") 'e))
(newline)
d
(apply (begin (display "f") list) (begin (display "1") 1) (begin (display "rest") '(2 3)))
(newline)
(define (show x) (display x) x)
(- (show 10) (show 3) (show 2))
(cons (show 'car) (show 'cdr))
(if (show #f) (show 'then) (show 'else))
(newline)
(string-append (show "a") (show "b") (show "c"))
((show (lambda (x) (show x))) (show 'inner))
(show (show (show 'nested)))
((show car) (show (list (show 'deep))))
""", ['op-arg1', '', 'f123(1 2 3)', '', 'abc(#<void> #<void> #<void>)', '', 'xyz',
      '(#<void> #<void> #<void>)', '12', 'ok', '12', 'ok', 'ab', 'ok', 't1t2t3yes', '',
      '123#f', '', '1233', '', 'define-value', 'set-value', 'e', 'f1rest(1 2 3)', '',
      '10325', 'carcdr(car . cdr)', '#felseelse', '', 'abc"abc"', '#<procedure>innerinnerinner',
      'nestednestednestednested', '#<procedure>deep(deep)deep'])

add('variadic', """(define (f . args) args)
(f) (f 1) (f 1 2 3)
(define (g a . rest) (list a rest))
(g 1) (g 1 2) (g 1 2 3)
(define (h a b . rest) (list a b rest))
(h 1 2) (h 1 2 3 4)
((lambda x x))
((lambda x x) 1 2)
((lambda (a . b) (cons b a)) 1 2 3)
(define (count . xs) (let loop ((l xs) (n 0)) (if (null? l) n (loop (cdr l) (+ n 1)))))
(count) (count 'a 'b 'c 'd)
(define (fresh . xs) xs)
(let ((a (fresh 1 2)) (b (fresh 1 2))) (list (equal? a b) (eq? a b)))
(g)
""", ['()', '(1)', '(1 2 3)', '(1 ())', '(1 (2))', '(1 (2 3))', '(1 2 ())', '(1 2 (3 4))',
      '()', '(1 2)', '((2 3) . 1)', '0', '4', '(#t #f)', 'error: arity-error'])

add('internal_define', """(define (f x)
  (define y (* x 2))
  (define (g z) (+ y z))
  (g 1))
(f 5)
(define (even-odd n)
  (define (ev? n) (if (= n 0) #t (od? (- n 1))))
  (define (od? n) (if (= n 0) #f (ev? (- n 1))))
  (list (ev? n) (od? n)))
(even-odd 11)
(define (outer)
  (define v 'inner)
  v)
(define v 'global)
(outer)
v
(define (mk)
  (define count 0)
  (lambda () (set! count (+ count 1)) count))
(define k (mk))
(k) (k)
(define (nested)
  (define (a) (b))
  (define (b) 'b-result)
  (a))
(nested)
(define (redefine-in-body x)
  (define x 99)
  x)
(redefine-in-body 1)
(define (uses-later)
  (define result (helper 3))
  result)
(define (helper n) (* n n))
(uses-later)
(let ((q 1))
  (define r (+ q 1))
  (define q 10)
  (list q r))
(define (with-begin)
  (begin (define bb 5))
  bb)
(with-begin)
(define (conditional-define flag)
  (if flag (define cd 'yes) (define cd 'no))
  cd)
(conditional-define #t)
(conditional-define #f)
(define (counter-pair)
  (define n 0)
  (define (inc) (set! n (+ n 1)) n)
  (define (get) n)
  (list inc get))
(define cp (counter-pair))
((car cp)) ((car cp)) ((car (cdr cp)))
""", ['11', '(#f #t)', 'inner', 'global', '1', '2', 'b-result', '99', '9', '(10 2)', '5',
      'yes', 'no', '1', '2', '2'])

add('higher_order', """(define (map f l) (if (null? l) '() (cons (f (car l)) (map f (cdr l)))))
(define (filter p l) (cond ((null? l) '()) ((p (car l)) (cons (car l) (filter p (cdr l)))) (else (filter p (cdr l)))))
(define (foldl f acc l) (if (null? l) acc (foldl f (f acc (car l)) (cdr l))))
(define (foldr f init l) (if (null? l) init (f (car l) (foldr f init (cdr l)))))
(define (range a b) (if (>= a b) '() (cons a (range (+ a 1) b))))
(define (assq k al) (cond ((null? al) #f) ((eq? (caar al) k) (car al)) (else (assq k (cdr al)))))
(define (caar x) (car (car x)))
(map (lambda (x) (* x x)) (range 1 6))
(filter (lambda (x) (= (remainder x 2) 0)) (range 1 11))
(foldl + 0 (range 1 101))
(foldl (lambda (acc x) (cons x acc)) '() '(1 2 3))
(foldr cons '() '(1 2 3))
(foldr (lambda (x acc) (+ x acc)) 0 (range 1 11))
(map (lambda (p) (car p)) '((1 . 2) (3 . 4)))
(map (lambda (x) (list x x)) '(a b))
(assq 'b '((a . 1) (b . 2) (c . 3)))
(assq 'z '((a . 1) (b . 2) (c . 3)))
(cdr (assq 'c '((a . 1) (b . 2) (c . 3))))
(define (for-each f l) (if (null? l) (if #f #f) (begin (f (car l)) (for-each f (cdr l)))))
(for-each (lambda (x) (display x) (display " ")) '(1 2 3)) (newline)
(define (zip a b) (if (or (null? a) (null? b)) '() (cons (list (car a) (car b)) (zip (cdr a) (cdr b)))))
(zip '(1 2 3) '(a b c d))
(define (compose . fs) (if (null? fs) (lambda (x) x) (lambda (x) ((car fs) ((apply compose (cdr fs)) x)))))
((compose (lambda (x) (* x 2)) (lambda (x) (+ x 1))) 5)
((compose) 7)
(map (lambda (f) (f 10)) (list (lambda (x) (+ x 1)) (lambda (x) (* x 2)) number->string))
(define (flatten t) (cond ((null? t) '()) ((pair? t) (append (flatten (car t)) (flatten (cdr t)))) (else (list t))))
(define (append a b) (foldr cons b a))
(flatten '(1 (2 (3 4)) ((5)) 6))
(foldl * 1 (range 1 21))
(map (lambda (x y) (+ x y)) '(1 2))
""", ['(1 4 9 16 25)', '(2 4 6 8 10)', '5050', '(3 2 1)', '(1 2 3)', '55', '(1 3)',
      '((a a) (b b))', '(b . 2)', '#f', '3', '1 2 3', '((1 a) (2 b) (3 c))', '12', '7',
      '(11 20 "10")', '(1 2 3 4 5 6)', '2432902008176640000', 'error: arity-error'])

add('symbols_predicates', """'hello-world
'a.b
'1+
'->
'<=?
'CamelCase
(eq? 'abc 'ABC)
(eq? 'abc 'abc)
(symbol? 'x) (symbol? "x") (symbol? 5) (symbol? '())
(number? 5) (number? -5) (number? "5") (number? '())
(boolean? #t) (boolean? #f) (boolean? 0) (boolean? '())
(string? "") (string? 's)
(procedure? car) (procedure? 'car) (procedure? (lambda () 1))
(define + -)
(+ 10 3)
(define (if-like c a b) (if c a b))
(if-like #t 1 2)
(symbol->string 'abc)
(string-append (symbol->string 'foo) "-" (symbol->string 'bar))
(list 'a 'b (list 'c 'd) "e" 'f)
'(#t #f)
'(1 . (2 3))
(number->string (* 99 99))
(pair? 'pair?)
(define list 'not-a-procedure)
list
(list 1 2)
""", ['hello-world', 'a.b', '1+', '->', '<=?', 'CamelCase', '#f', '#t', '#t', '#f', '#f', '#f',
      '#t', '#t', '#f', '#f', '#t', '#t', '#f', '#f', '#t', '#f', '#t', '#f', '#t', '7', '1',
      '"abc"', '"foo-bar"', '(a b (c d) "e" f)', '(#t #f)', '(1 2 3)', '"9801"', '#f',
      'not-a-procedure', 'error: type-error'])

# ---------------------------------------------------------------------------
# Error cases: one category per test because an error stops the program
# ---------------------------------------------------------------------------

add('error_unbound', '''(define x 1)
(display "before")
(newline)
x
y
(display "after")
''', ['before', '1', 'error: unbound-variable'])

add('error_type_car', """(define (safe-car l) (if (pair? l) (car l) 'empty))
(safe-car '())
(display "ok")
(newline)
(car '())
(display "after")
""", ['empty', 'ok', 'error: type-error'])

add('error_type_arith', '''(+ 1 2)
(+ 1 #t)
(display "after")
''', ['3', 'error: type-error'])

add('error_type_string', '''(string-length "abc")
(string-append "a" 'b)
''', ['3', 'error: type-error'])

add('error_nonproc', '''(define x 5)
(display "a")
(x (display "operand") (display "s"))
(display "after")
''', ['aoperandserror: type-error'])

add('error_arity_closure', '''(define (f a b) (+ a b))
(f 1 2)
(f 1)
(f 1 2 3)
''', ['3', 'error: arity-error'])

add('error_arity_too_many', '''(define (f a b) (+ a b))
(f 1 2)
((lambda (a . rest) rest) 1 2 3)
((lambda (a . rest) rest))
''', ['3', '(2 3)', 'error: arity-error'])

add('error_arity_prim', '''(display "x")
(newline)
(cons 1)
(display "after")
''', ['x', 'error: arity-error'])

add('error_divzero', '''(quotient 7 2)
(remainder 7 0)
(display "after")
''', ['3', 'error: division-by-zero'])

add('error_divzero_quotient', '''(define (safe-div a b) (if (= b 0) 'inf (quotient a b)))
(safe-div 1 0)
(quotient 1 0)
''', ['inf', 'error: division-by-zero'])

add('error_user', '''(define (check x) (if (< x 0) (error "negative" x) x))
(check 5)
(check -1)
(check 7)
''', ['5', 'error: user-error'])

add('error_user_noargs', '''(display "about to fail")
(newline)
(error)
''', ['about to fail', 'error: user-error'])

add('error_after_output', '''(display "partial")
(car (display "x") (display "y"))
''', ['partialxyerror: arity-error'])

add('error_set_unbound', '''(define x 1)
(set! x 2)
x
(set! nope (begin (display "evaluated") 3))
x
''', ['2', 'evaluatederror: unbound-variable'])

add('error_apply_improper', """(apply + '(1 2))
(apply + '(1 2 . 3))
""", ['3', 'error: type-error'])

add('error_in_deep_loop', '''(define (loop i) (if (= i 500000) (car i) (loop (+ i 1))))
(display "start")
(newline)
(loop 0)
''', ['start', 'error: type-error'])

add('error_unbound_in_closure', '''(define (f) (g))
(display "defined")
(newline)
(f)
''', ['defined', 'error: unbound-variable'])

# ---------------------------------------------------------------------------
# Classic programs
# ---------------------------------------------------------------------------

add('factorial_100', '''(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
(fact 0)
(fact 1)
(fact 5)
(fact 20)
(fact 30)
(fact 50)
(fact 100)
(define (fact-iter n) (let loop ((i n) (acc 1)) (if (= i 0) acc (loop (- i 1) (* acc i)))))
(fact-iter 100)
(= (fact 100) (fact-iter 100))
(string-length (number->string (fact 100)))
''', [str(math.factorial(n)) for n in (0, 1, 5, 20, 30, 50, 100)] +
     [str(math.factorial(100)), '#t', str(len(str(math.factorial(100))))])


def fib(n):
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a


add('fib', '''(define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
(define (range a b) (if (>= a b) '() (cons a (range (+ a 1) b))))
(define (map f l) (if (null? l) '() (cons (f (car l)) (map f (cdr l)))))
(map fib (range 0 21))
(fib 20)
(define (fib-iter n) (let loop ((i 0) (a 0) (b 1)) (if (= i n) a (loop (+ i 1) b (+ a b)))))
(fib-iter 90)
(fib-iter 100)
(fib-iter 500)
(fib-iter 1000)
(string-length (number->string (fib-iter 1000)))
(= (fib 20) (fib-iter 20))
''', ['(' + ' '.join(str(fib(i)) for i in range(21)) + ')', str(fib(20)), str(fib(90)),
      str(fib(100)), str(fib(500)), str(fib(1000)), str(len(str(fib(1000)))), '#t'])

add('y_combinator', '''(define Y
  (lambda (f)
    ((lambda (x) (f (lambda (v) ((x x) v))))
     (lambda (x) (f (lambda (v) ((x x) v)))))))
(define fact
  (Y (lambda (self)
       (lambda (n) (if (= n 0) 1 (* n (self (- n 1))))))))
(fact 10)
(fact 25)
(define fib
  (Y (lambda (self)
       (lambda (n) (if (< n 2) n (+ (self (- n 1)) (self (- n 2))))))))
(fib 20)
((Y (lambda (self) (lambda (l) (if (null? l) 0 (+ 1 (self (cdr l))))))) '(a b c d))
(define Y2
  (lambda (f)
    ((lambda (x) (f (lambda (a b) ((x x) a b))))
     (lambda (x) (f (lambda (a b) ((x x) a b)))))))
((Y2 (lambda (self) (lambda (a b) (if (= b 0) a (self b (remainder a b)))))) 1071 462)
((Y (lambda (self) (lambda (n) (if (= n 0) 'done (self (- n 1)))))) 100000)
''', [str(math.factorial(10)), str(math.factorial(25)), str(fib(20)), '4', str(math.gcd(1071, 462)),
      'done'])

add('mutual_recursion', """(define (my-even? n) (if (= n 0) #t (my-odd? (- n 1))))
(define (my-odd? n) (if (= n 0) #f (my-even? (- n 1))))
(my-even? 1000000)
(my-odd? 1000000)
(my-even? 1000001)
(my-odd? 777777)
(letrec ((ev? (lambda (n) (if (= n 0) #t (od? (- n 1)))))
         (od? (lambda (n) (if (= n 0) #f (ev? (- n 1))))))
  (list (ev? 300000) (od? 300001)))
(define (mod3-0 n) (cond ((= n 0) 0) (else (mod3-1 (- n 1)))))
(define (mod3-1 n) (cond ((= n 0) 1) (else (mod3-2 (- n 1)))))
(define (mod3-2 n) (cond ((= n 0) 2) (else (mod3-0 (- n 1)))))
(mod3-0 300000)
(mod3-0 300001)
(mod3-0 300002)
(define (ping n acc) (if (= n 0) acc (pong (- n 1) (cons 'ping acc))))
(define (pong n acc) (if (= n 0) acc (ping (- n 1) (cons 'pong acc))))
(ping 5 '())
""", ['#t', '#f', '#f', '#t', '(#t #t)', str(300000 % 3), str(300001 % 3), str(300002 % 3),
      '(pong ping pong ping ping)'])
# ping 5: ping->pong(4, (ping)) ->ping(3,(pong ping)) ->pong(2,(ping pong ping))
# ->ping(1,(pong ping pong ping)) ->pong(0,(ping pong ping pong ping)) -> (ping pong ping pong ping)
cases[-1] = (cases[-1][0], cases[-1][1], cases[-1][2][:-1] + ['(ping pong ping pong ping)'])

add('counters_accounts', """(define (make-account balance)
  (define (withdraw amount)
    (if (>= balance amount)
        (begin (set! balance (- balance amount)) balance)
        "Insufficient funds"))
  (define (deposit amount)
    (set! balance (+ balance amount))
    balance)
  (define (dispatch m)
    (cond ((eq? m 'withdraw) withdraw)
          ((eq? m 'deposit) deposit)
          ((eq? m 'balance) balance)
          (else (error "Unknown request" m))))
  dispatch)
(define acc (make-account 100))
((acc 'withdraw) 50)
((acc 'withdraw) 60)
((acc 'deposit) 40)
((acc 'withdraw) 60)
(acc 'balance)
(define acc2 (make-account 10))
((acc2 'deposit) 5)
(acc 'balance)
(acc2 'balance)
(define (make-accumulator sum)
  (lambda (x) (set! sum (+ sum x)) sum))
(define A (make-accumulator 5))
(A 10)
(A 10)
(define (make-monitored f)
  (let ((calls 0))
    (lambda (x)
      (cond ((eq? x 'how-many-calls?) calls)
            ((eq? x 'reset-count) (set! calls 0) 'reset)
            (else (set! calls (+ calls 1)) (f x))))))
(define m (make-monitored (lambda (x) (* x x))))
(m 10)
(m 20)
(m 'how-many-calls?)
(m 'reset-count)
(m 'how-many-calls?)
(define (make-stack)
  (let ((items '()))
    (lambda (op . args)
      (cond ((eq? op 'push) (set! items (cons (car args) items)) items)
            ((eq? op 'pop) (let ((top (car items))) (set! items (cdr items)) top))
            ((eq? op 'peek) (car items))
            (else (error "bad op"))))))
(define s (make-stack))
(s 'push 1)
(s 'push 2)
(s 'push 3)
(s 'pop)
(s 'peek)
(s 'pop)
(s 'pop)
(s 'pop)
""", ['50', '"Insufficient funds"', '90', '30', '30', '15', '30', '15', '15', '25', '100', '400',
      '2', 'reset', '0', '(1)', '(2 1)', '(3 2 1)', '3', '2', '2', '1', 'error: type-error'])

add('symbolic_deriv', """(define (map f l) (if (null? l) '() (cons (f (car l)) (map f (cdr l)))))
(define (cadr x) (car (cdr x)))
(define (caddr x) (car (cdr (cdr x))))
(define (variable? x) (symbol? x))
(define (same-variable? v1 v2) (and (variable? v1) (variable? v2) (eq? v1 v2)))
(define (=number? exp num) (and (number? exp) (= exp num)))
(define (make-sum a1 a2)
  (cond ((=number? a1 0) a2)
        ((=number? a2 0) a1)
        ((and (number? a1) (number? a2)) (+ a1 a2))
        (else (list '+ a1 a2))))
(define (make-product m1 m2)
  (cond ((or (=number? m1 0) (=number? m2 0)) 0)
        ((=number? m1 1) m2)
        ((=number? m2 1) m1)
        ((and (number? m1) (number? m2)) (* m1 m2))
        (else (list '* m1 m2))))
(define (sum? x) (and (pair? x) (eq? (car x) '+)))
(define (addend s) (cadr s))
(define (augend s) (caddr s))
(define (product? x) (and (pair? x) (eq? (car x) '*)))
(define (multiplier p) (cadr p))
(define (multiplicand p) (caddr p))
(define (deriv exp var)
  (cond ((number? exp) 0)
        ((variable? exp) (if (same-variable? exp var) 1 0))
        ((sum? exp) (make-sum (deriv (addend exp) var) (deriv (augend exp) var)))
        ((product? exp)
         (make-sum (make-product (multiplier exp) (deriv (multiplicand exp) var))
                   (make-product (deriv (multiplier exp) var) (multiplicand exp))))
        (else (error "unknown expression type" exp))))
(deriv '(+ x 3) 'x)
(deriv '(* x y) 'x)
(deriv '(* (* x y) (+ x 3)) 'x)
(deriv '(* x x) 'x)
(deriv 'y 'x)
(deriv 5 'x)
(deriv '(+ (* 3 x) (* x (* x x))) 'x)
(define (evaluate exp env)
  (cond ((number? exp) exp)
        ((symbol? exp) (cdr (assq exp env)))
        ((sum? exp) (+ (evaluate (addend exp) env) (evaluate (augend exp) env)))
        ((product? exp) (* (evaluate (multiplier exp) env) (evaluate (multiplicand exp) env)))
        (else (error "bad"))))
(define (assq k al) (cond ((null? al) #f) ((eq? (car (car al)) k) (car al)) (else (assq k (cdr al)))))
(evaluate (deriv '(* (* x y) (+ x 3)) 'x) '((x . 2) (y . 5)))
(deriv '(- x 1) 'x)
""", ['1', 'y', '(+ (* x y) (* y (+ x 3)))', '(+ x x)', '0', '0', '(+ 3 (+ (* x (+ x x)) (* x x)))',
      '35', 'error: user-error'])


def ack(m, n):
    stack = [m]
    while stack:
        m = stack.pop()
        if m == 0:
            n += 1
        elif n == 0:
            stack.append(m - 1)
            n = 1
        else:
            stack.append(m - 1)
            stack.append(m)
            n -= 1
    return n


def tak(x, y, z):
    if not (y < x):
        return z
    return tak(tak(x - 1, y, z), tak(y - 1, z, x), tak(z - 1, x, y))


add('ackermann_tak_hanoi', '''(define (ack m n)
  (cond ((= m 0) (+ n 1))
        ((= n 0) (ack (- m 1) 1))
        (else (ack (- m 1) (ack m (- n 1))))))
(ack 0 0) (ack 1 2) (ack 2 3) (ack 3 3) (ack 3 5)
(define (tak x y z)
  (if (not (< y x)) z
      (tak (tak (- x 1) y z) (tak (- y 1) z x) (tak (- z 1) x y))))
(tak 18 12 6)
(tak 12 8 4)
(define (hanoi n from to via)
  (if (= n 0) 0
      (+ (hanoi (- n 1) from via to) 1 (hanoi (- n 1) via to from))))
(hanoi 10 'a 'c 'b)
(hanoi 16 'a 'c 'b)
(define moves '())
(define (hanoi-moves n from to via)
  (if (> n 0)
      (begin (hanoi-moves (- n 1) from via to)
             (set! moves (cons (list from to) moves))
             (hanoi-moves (- n 1) via to from))))
(hanoi-moves 3 'a 'c 'b)
(define (reverse l) (let loop ((l l) (r '())) (if (null? l) r (loop (cdr l) (cons (car l) r)))))
(reverse moves)
''', [str(ack(0, 0)), str(ack(1, 2)), str(ack(2, 3)), str(ack(3, 3)), str(ack(3, 5)),
      str(tak(18, 12, 6)), str(tak(12, 8, 4)), str(2 ** 10 - 1), str(2 ** 16 - 1),
      '((a c) (a b) (c b) (a c) (b a) (b c) (a c))'])


def lcg_list(n, seed):
    out = []
    x = seed
    for _ in range(n):
        x = (x * 1103515245 + 12345) % 2147483648
        out.append(x % 100000)
    return out


LCG_N = 2000
lcg = lcg_list(LCG_N, 42)
lcg_sorted = sorted(lcg)
add('sorting', '''(define (lcg-list n seed)
  (let loop ((i 0) (x seed) (acc '()))
    (if (= i n) (reverse acc)
        (let ((nx (remainder (+ (* x 1103515245) 12345) 2147483648)))
          (loop (+ i 1) nx (cons (remainder nx 100000) acc))))))
(define (reverse l) (let loop ((l l) (r '())) (if (null? l) r (loop (cdr l) (cons (car l) r)))))
(define (length l) (let loop ((l l) (n 0)) (if (null? l) n (loop (cdr l) (+ n 1)))))
(define (take l n) (if (= n 0) '() (cons (car l) (take (cdr l) (- n 1)))))
(define (drop l n) (if (= n 0) l (drop (cdr l) (- n 1))))
(define (merge a b)
  (cond ((null? a) b)
        ((null? b) a)
        ((<= (car a) (car b)) (cons (car a) (merge (cdr a) b)))
        (else (cons (car b) (merge a (cdr b))))))
(define (msort l)
  (let ((n (length l)))
    (if (< n 2) l
        (let ((h (quotient n 2)))
          (merge (msort (take l h)) (msort (drop l h)))))))
(define (filter p l) (cond ((null? l) '()) ((p (car l)) (cons (car l) (filter p (cdr l)))) (else (filter p (cdr l)))))
(define (append a b) (if (null? a) b (cons (car a) (append (cdr a) b))))
(define (qsort l)
  (if (null? l) '()
      (let ((p (car l)) (rest (cdr l)))
        (append (qsort (filter (lambda (x) (< x p)) rest))
                (cons p (qsort (filter (lambda (x) (>= x p)) rest)))))))
(define (sorted? l) (or (null? l) (null? (cdr l)) (and (<= (car l) (car (cdr l))) (sorted? (cdr l)))))
(define (sum l) (let loop ((l l) (s 0)) (if (null? l) s (loop (cdr l) (+ s (car l))))))
(define data (lcg-list %d 42))
(take data 10)
(sum data)
(define m (msort data))
(define q (qsort data))
(sorted? data)
(sorted? m)
(equal? m q)
(take m 10)
(take (reverse m) 10)
(sum m)
(length m)
(msort '())
(msort '(1))
(qsort '(3 1 2))
(msort '(5 5 5 1 1))
''' % LCG_N, ['(' + ' '.join(map(str, lcg[:10])) + ')', str(sum(lcg)),
              '#f', '#t', '#t', '(' + ' '.join(map(str, lcg_sorted[:10])) + ')',
              '(' + ' '.join(map(str, lcg_sorted[::-1][:10])) + ')', str(sum(lcg)), str(LCG_N),
              '()', '(1)', '(1 2 3)', '(1 1 5 5 5)'])


def tq(a, b):
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


def tr(a, b):
    return a - b * tq(a, b)


big1 = 2 ** 1000
big2 = 3 ** 300
f300 = math.factorial(300)
add('bigint', '''(define (expt b e) (if (= e 0) 1 (* b (expt b (- e 1)))))
(define (fact n) (let loop ((i n) (acc 1)) (if (= i 0) acc (loop (- i 1) (* acc i)))))
(expt 2 1000)
(expt 3 300)
(string-length (number->string (fact 300)))
(quotient (fact 300) (fact 299))
(remainder (fact 300) (fact 299))
(quotient (expt 2 1000) (expt 3 300))
(remainder (expt 2 1000) (expt 3 300))
(quotient (- (expt 2 1000)) (expt 3 300))
(remainder (- (expt 2 1000)) (expt 3 300))
(quotient (expt 2 1000) (- (expt 3 300)))
(remainder (expt 2 1000) (- (expt 3 300)))
(quotient (- (expt 2 1000)) (- (expt 3 300)))
(remainder (- (expt 2 1000)) (- (expt 3 300)))
(- (expt 2 1000) (expt 2 1000))
(- (expt 2 1000) (expt 2 999) (expt 2 999))
(* (expt 2 500) (expt 2 500))
(= (* (expt 2 500) (expt 2 500)) (expt 2 1000))
(< (expt 2 1000) (expt 3 700))
(> (expt 2 1000) (expt 3 600))
(- (expt 10 30))
(+ (- (expt 10 30)) 1)
(quotient (expt 10 30) (expt 10 15))
(remainder (+ (expt 10 30) 7) (expt 10 15))
(quotient -1000000000000000000000000000001 10)
(remainder -1000000000000000000000000000001 10)
(* -1 (expt 2 64))
(+ (expt 2 64) -1)
(= 18446744073709551616 (expt 2 64))
(- 9223372036854775808 1)
(+ 9223372036854775807 1)
(* 4294967296 4294967296)
(- -9223372036854775808 1)
''', [str(big1), str(big2), str(len(str(f300))), '300', '0',
      str(tq(big1, big2)), str(tr(big1, big2)), str(tq(-big1, big2)), str(tr(-big1, big2)),
      str(tq(big1, -big2)), str(tr(big1, -big2)), str(tq(-big1, -big2)), str(tr(-big1, -big2)),
      '0', '0', str(2 ** 1000), '#t', '#t' if big1 < 3 ** 700 else '#f',
      '#t' if big1 > 3 ** 600 else '#f', str(-10 ** 30), str(-10 ** 30 + 1), str(10 ** 15),
      '7', str(tq(-10 ** 30 - 1, 10)), str(tr(-10 ** 30 - 1, 10)), str(-2 ** 64), str(2 ** 64 - 1),
      '#t', str(2 ** 63 - 1), str(2 ** 63), str(2 ** 64), str(-2 ** 63 - 1)])

# ---------------------------------------------------------------------------
# Randomised tests with independent Python oracles
# ---------------------------------------------------------------------------


def gen_arith(rng, depth):
    """Returns (scheme_text, python_value) for a random integer expression."""
    if depth == 0 or rng.random() < 0.25:
        v = rng.randint(-60, 60)
        return (str(v), v)
    op = rng.choice(['+', '+', '-', '-', '*', 'quotient', 'remainder', 'neg'])
    if op == 'neg':
        t, v = gen_arith(rng, depth - 1)
        return ('(- %s)' % t, -v)
    if op in ('+', '*'):
        n = rng.randint(0, 4)
        parts = [gen_arith(rng, depth - 1) for _ in range(n)]
        v = 0 if op == '+' else 1
        for _, pv in parts:
            v = v + pv if op == '+' else v * pv
        return ('(%s%s)' % (op, ''.join(' ' + t for t, _ in parts)), v)
    if op == '-':
        n = rng.randint(1, 4)
        parts = [gen_arith(rng, depth - 1) for _ in range(n)]
        if n == 1:
            return ('(- %s)' % parts[0][0], -parts[0][1])
        v = parts[0][1]
        for _, pv in parts[1:]:
            v -= pv
        return ('(- %s)' % ' '.join(t for t, _ in parts), v)
    a = gen_arith(rng, depth - 1)
    b = gen_arith(rng, depth - 1)
    while b[1] == 0:
        b = gen_arith(rng, depth - 1)
    if op == 'quotient':
        return ('(quotient %s %s)' % (a[0], b[0]), tq(a[1], b[1]))
    return ('(remainder %s %s)' % (a[0], b[0]), tr(a[1], b[1]))


CMP = {'=': lambda x, y: x == y, '<': lambda x, y: x < y, '>': lambda x, y: x > y,
       '<=': lambda x, y: x <= y, '>=': lambda x, y: x >= y}


def gen_bool(rng, depth):
    """Returns (scheme_text, python_bool) for a random boolean expression."""
    if depth == 0 or rng.random() < 0.3:
        op = rng.choice(list(CMP))
        n = rng.randint(2, 3)
        parts = [gen_arith(rng, 2) for _ in range(n)]
        v = all(CMP[op](parts[i][1], parts[i + 1][1]) for i in range(n - 1))
        return ('(%s %s)' % (op, ' '.join(t for t, _ in parts)), v)
    op = rng.choice(['and', 'or', 'not', 'if'])
    if op == 'not':
        t, v = gen_bool(rng, depth - 1)
        return ('(not %s)' % t, not v)
    if op == 'if':
        c = gen_bool(rng, depth - 1)
        a = gen_bool(rng, depth - 1)
        b = gen_bool(rng, depth - 1)
        return ('(if %s %s %s)' % (c[0], a[0], b[0]), a[1] if c[1] else b[1])
    n = rng.randint(0, 3)
    parts = [gen_bool(rng, depth - 1) for _ in range(n)]
    v = all(p[1] for p in parts) if op == 'and' else any(p[1] for p in parts)
    return ('(%s%s)' % (op, ''.join(' ' + t for t, _ in parts)), v)


def random_arith_case(seed, lines):
    rng = random.Random(seed)
    prog, exp = [], []
    for i in range(lines):
        if i % 4 == 3:
            t, v = gen_bool(rng, 3)
            prog.append(t)
            exp.append('#t' if v else '#f')
        else:
            t, v = gen_arith(rng, rng.randint(2, 5))
            prog.append(t)
            exp.append(str(v))
    return '\n'.join(prog) + '\n', exp


for i, seed in enumerate((1001, 1002, 1003)):
    p, e = random_arith_case(seed, 250)
    add('random_arith_%d' % (i + 1), p, e)


SYMBOL_CHARS = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-+*/<=>!?_.:'


def gen_datum(rng, depth):
    """Returns a Python model of a random datum.

    Model: int, bool, ('str', s), ('sym', name), ('nil',), ('pair', car, cdr).
    """
    r = rng.random()
    if depth == 0 or r < 0.45:
        k = rng.randint(0, 4)
        if k == 0:
            return rng.randint(-10 ** 6, 10 ** 6)
        if k == 1:
            return rng.random() < 0.5
        if k == 2:
            chars = 'ab c\\"\n\t;()\'xyz'
            return ('str', ''.join(rng.choice(chars) for _ in range(rng.randint(0, 6))))
        if k == 3:
            name = ''.join(rng.choice(SYMBOL_CHARS) for _ in range(rng.randint(1, 6)))
            while name.lstrip('+-').isdigit() or name == '.' or name[0] == '#':
                name = ''.join(rng.choice(SYMBOL_CHARS) for _ in range(rng.randint(1, 6)))
            return ('sym', name)
        return ('nil',)
    n = rng.randint(0, 4)
    items = [gen_datum(rng, depth - 1) for _ in range(n)]
    tail = ('nil',)
    if n > 0 and rng.random() < 0.25:
        tail = gen_datum(rng, 0)
        if tail == ('nil',):
            tail = 0
    for x in reversed(items):
        tail = ('pair', x, tail)
    return tail


def is_pair(d):
    return isinstance(d, tuple) and d[0] == 'pair'


def is_nil(d):
    return isinstance(d, tuple) and d[0] == 'nil'


def write_datum(d, display=False):
    if isinstance(d, bool):
        return '#t' if d else '#f'
    if isinstance(d, int):
        return str(d)
    if d[0] == 'str':
        if display:
            return d[1]
        s = d[1].replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\t', '\\t')
        return '"' + s + '"'
    if d[0] == 'sym':
        return d[1]
    if d[0] == 'nil':
        return '()'
    parts = []
    while is_pair(d):
        parts.append(write_datum(d[1], display))
        d = d[2]
    if not is_nil(d):
        parts.append('.')
        parts.append(write_datum(d, display))
    return '(' + ' '.join(parts) + ')'


def source_datum(rng, d):
    """Writes d in Scheme source syntax, randomly varying spacing and
    using explicit dotted notation for some proper tails so that the reader
    is exercised on `(a . (b c))` style input too."""
    if not is_pair(d):
        return write_datum(d)
    parts = []
    while is_pair(d):
        parts.append(source_datum(rng, d[1]))
        d = d[2]
        if is_pair(d) and rng.random() < 0.15:
            parts.append('.')
            parts.append(source_datum(rng, d))
            d = ('nil',)
            break
    if not is_nil(d):
        parts.append('.')
        parts.append(source_datum(rng, d))
    sep = rng.choice([' ', '  ', '\n ', ' ; comment\n '])
    return '(' + rng.choice(['', ' ']) + sep.join(parts) + rng.choice(['', ' ']) + ')'


def random_data_case(seed, count):
    rng = random.Random(seed)
    prog, exp = [], []
    for _ in range(count):
        d = gen_datum(rng, 4)
        src = source_datum(rng, d)
        prog.append("'" + src if rng.random() < 0.7 else '(quote ' + src + ')')
        exp.append(write_datum(d))
        prog.append("(display '%s) (newline)" % src)
        exp.append(write_datum(d, True))
        if is_pair(d):
            prog.append("(car '%s)" % src)
            exp.append(write_datum(d[1]))
            prog.append("(cdr '%s)" % src)
            exp.append(write_datum(d[2]))
            prog.append("(pair? '%s)" % src)
            exp.append('#t')
        prog.append("(equal? '%s '%s)" % (src, source_datum(rng, d)))
        exp.append('#t')
    return '\n'.join(prog) + '\n', exp


for i, seed in enumerate((2001, 2002)):
    p, e = random_data_case(seed, 60)
    add('random_data_%d' % (i + 1), p, e)


def random_program_case(seed, count):
    """Straight-line program of defines over ints with let/if/lambda, with
    each value computed independently while generating."""
    rng = random.Random(seed)
    env = {}
    prog, exp = [], []

    def expr(depth, scope):
        if depth == 0 or rng.random() < 0.2:
            if scope and rng.random() < 0.6:
                name = rng.choice(list(scope))
                return name, scope[name]
            v = rng.randint(-30, 30)
            return str(v), v
        k = rng.choice(['arith', 'if', 'let', 'let*', 'lambda', 'begin', 'cond'])
        if k == 'arith':
            op = rng.choice(['+', '-', '*', 'quotient', 'remainder'])
            a = expr(depth - 1, scope)
            b = expr(depth - 1, scope)
            if op in ('quotient', 'remainder'):
                while b[1] == 0:
                    b = expr(depth - 1, scope)
                v = tq(a[1], b[1]) if op == 'quotient' else tr(a[1], b[1])
            else:
                v = {'+': a[1] + b[1], '-': a[1] - b[1], '*': a[1] * b[1]}[op]
            return '(%s %s %s)' % (op, a[0], b[0]), v
        if k == 'if':
            cop = rng.choice(list(CMP))
            a = expr(depth - 1, scope)
            b = expr(depth - 1, scope)
            t = expr(depth - 1, scope)
            f = expr(depth - 1, scope)
            c = CMP[cop](a[1], b[1])
            return '(if (%s %s %s) %s %s)' % (cop, a[0], b[0], t[0], f[0]), t[1] if c else f[1]
        if k == 'cond':
            cop = rng.choice(list(CMP))
            a = expr(depth - 1, scope)
            b = expr(depth - 1, scope)
            t = expr(depth - 1, scope)
            f = expr(depth - 1, scope)
            c = CMP[cop](a[1], b[1])
            return '(cond ((%s %s %s) %s) (else %s))' % (cop, a[0], b[0], t[0], f[0]), t[1] if c else f[1]
        if k in ('let', 'let*'):
            names = rng.sample(['p', 'q', 'r', 's'], rng.randint(1, 2))
            inner = dict(scope)
            binds = []
            for nm in names:
                e = expr(depth - 1, scope if k == 'let' else inner)
                binds.append('(%s %s)' % (nm, e[0]))
                if k == 'let*':
                    inner[nm] = e[1]
                else:
                    inner[nm] = e[1]
            body = expr(depth - 1, inner)
            return '(%s (%s) %s)' % (k, ' '.join(binds), body[0]), body[1]
        if k == 'lambda':
            nm = rng.choice(['u', 'w'])
            arg = expr(depth - 1, scope)
            inner = dict(scope)
            inner[nm] = arg[1]
            body = expr(depth - 1, inner)
            return '((lambda (%s) %s) %s)' % (nm, body[0], arg[0]), body[1]
        a = expr(depth - 1, scope)
        b = expr(depth - 1, scope)
        return '(begin %s %s)' % (a[0], b[0]), b[1]

    for i in range(count):
        name = 'v%d' % i
        t, v = expr(rng.randint(1, 4), env)
        if rng.random() < 0.7:
            prog.append('(define %s %s)' % (name, t))
            env[name] = v
            prog.append(name)
            exp.append(str(v))
        else:
            prog.append(t)
            exp.append(str(v))
    names = list(env)
    prog.append('(list %s)' % ' '.join(names))
    exp.append('(' + ' '.join(str(env[n]) for n in names) + ')')
    prog.append('(+ %s)' % ' '.join(names))
    exp.append(str(sum(env[n] for n in names)))
    return '\n'.join(prog) + '\n', exp


for i, seed in enumerate((3001, 3002)):
    p, e = random_program_case(seed, 80)
    add('random_program_%d' % (i + 1), p, e)

# ---------------------------------------------------------------------------
# Larger programs and performance
# ---------------------------------------------------------------------------

add('deep_recursion_10000', """(define (count n) (if (= n 0) 0 (+ 1 (count (- n 1)))))
(count 10000)
(define (build n) (if (= n 0) '() (cons n (build (- n 1)))))
(define (sum l) (if (null? l) 0 (+ (car l) (sum (cdr l)))))
(sum (build 10000))
(define (length l) (if (null? l) 0 (+ 1 (length (cdr l)))))
(length (build 10000))
(define (append a b) (if (null? a) b (cons (car a) (append (cdr a) b))))
(length (append (build 5000) (build 5000)))
(define (map f l) (if (null? l) '() (cons (f (car l)) (map f (cdr l)))))
(sum (map (lambda (x) (* x x)) (build 10000)))
(define (nest n) (if (= n 0) 'x (list (nest (- n 1)))))
(define (depth t) (if (pair? t) (+ 1 (depth (car t))) 0))
(depth (nest 5000))
(equal? (nest 5000) (nest 5000))
(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
(string-length (number->string (fact 2000)))
(define (deep-let n) (if (= n 0) 0 (let ((r (deep-let (- n 1)))) (+ r 1))))
(deep-let 10000)
(define (deep-cond n) (cond ((= n 0) 0) (else (+ 1 (deep-cond (- n 1))))))
(deep-cond 10000)
""", ['10000', str(sum(range(1, 10001))), '10000', '10000', str(sum(i * i for i in range(1, 10001))),
      '5000', '#t', str(len(str(math.factorial(2000)))), '10000', '10000'])

add('eight_queens', """(define (map f l) (if (null? l) '() (cons (f (car l)) (map f (cdr l)))))
(define (abs x) (if (< x 0) (- x) x))
(define (queens n)
  (define (safe? col placed dist)
    (cond ((null? placed) #t)
          ((or (= (car placed) col) (= (abs (- (car placed) col)) dist)) #f)
          (else (safe? col (cdr placed) (+ dist 1)))))
  (define (place k placed)
    (if (= k n) 1
        (let loop ((col 0) (total 0))
          (if (= col n) total
              (loop (+ col 1)
                    (+ total (if (safe? col placed 1) (place (+ k 1) (cons col placed)) 0)))))))
  (place 0 '()))
(map queens '(1 2 3 4 5 6 7 8))
(queens 8)
(define (first-solution n)
  (define (safe? col placed dist)
    (cond ((null? placed) #t)
          ((or (= (car placed) col) (= (abs (- (car placed) col)) dist)) #f)
          (else (safe? col (cdr placed) (+ dist 1)))))
  (define (place k placed)
    (if (= k n) placed
        (let loop ((col 0))
          (if (= col n) #f
              (or (and (safe? col placed 1) (place (+ k 1) (cons col placed)))
                  (loop (+ col 1)))))))
  (place 0 '()))
(first-solution 8)
(first-solution 3)
""", ['(1 0 0 2 10 4 40 92)', '92', '(3 1 6 2 5 7 4 0)', '#f'])


def primes_below(n):
    s = [True] * n
    s[0] = s[1] = False
    for i in range(2, int(n ** 0.5) + 1):
        if s[i]:
            for j in range(i * i, n, i):
                s[j] = False
    return [i for i in range(n) if s[i]]


pr = primes_below(10001)
add('sieve', """(define (range a b) (let loop ((i b) (acc '())) (if (< i a) acc (loop (- i 1) (cons i acc)))))
(define (reverse l) (let loop ((l l) (r '())) (if (null? l) r (loop (cdr l) (cons (car l) r)))))
(define (filter p l)
  (let loop ((l l) (acc '()))
    (cond ((null? l) (reverse acc))
          ((p (car l)) (loop (cdr l) (cons (car l) acc)))
          (else (loop (cdr l) acc)))))
(define (length l) (let loop ((l l) (n 0)) (if (null? l) n (loop (cdr l) (+ n 1)))))
(define (sum l) (let loop ((l l) (s 0)) (if (null? l) s (loop (cdr l) (+ s (car l))))))
(define (take l n) (if (or (= n 0) (null? l)) '() (cons (car l) (take (cdr l) (- n 1)))))
(define (last l) (if (null? (cdr l)) (car l) (last (cdr l))))
(define (sieve l limit)
  (cond ((null? l) '())
        ((> (* (car l) (car l)) limit) l)
        (else (let ((p (car l)))
                (cons p (sieve (filter (lambda (x) (not (= (remainder x p) 0))) (cdr l)) limit))))))
(define primes (sieve (range 2 10000) 10000))
(length primes)
(sum primes)
(take primes 20)
(last primes)
(length (sieve (range 2 1000) 1000))
(sieve (range 2 30) 30)
(sieve '() 10)
""", [str(len(pr)), str(sum(pr)), '(' + ' '.join(map(str, pr[:20])) + ')', str(pr[-1]),
      str(len(primes_below(1001))), '(' + ' '.join(map(str, primes_below(31))) + ')', '()'])

add('tail_loop_1e6', """(let loop ((i 0) (acc 0))
  (if (= i 1000000) acc (loop (+ i 1) (+ acc i))))
(define (count-up i limit) (if (= i limit) i (count-up (+ i 1) limit)))
(count-up 0 1000000)
(define (sum-to n) (define (iter i acc) (if (> i n) acc (iter (+ i 1) (+ acc i)))) (iter 1 0))
(sum-to 1000000)
""", [str(sum(range(1000000))), '1000000', str(sum(range(1, 1000001)))])

N = 200000
add('tail_positions', """(define n %d)
(define (loop-if i) (if (= i 0) 'if-done (loop-if (- i 1))))
(loop-if n)
(define (loop-if-else i) (if (not (= i 0)) (loop-if-else (- i 1)) 'if-else-done))
(loop-if-else n)
(define (loop-cond i) (cond ((= i 0) 'cond-done) ((< i 0) 'negative) (else (loop-cond (- i 1)))))
(loop-cond n)
(define (loop-cond-mid i) (cond ((< i 0) 'negative) ((> i 0) (loop-cond-mid (- i 1))) (else 'cond-mid-done)))
(loop-cond-mid n)
(define (loop-and i) (and (>= i 0) (or (= i 0) (loop-and (- i 1)))))
(loop-and n)
(define (loop-or i) (or (= i 0) (loop-or (- i 1))))
(loop-or n)
(define counter 0)
(define (loop-begin i) (if (= i 0) 'begin-done (begin (set! counter (+ counter 1)) (loop-begin (- i 1)))))
(loop-begin n)
counter
(define (loop-let i) (let ((j (- i 1))) (if (< j 0) 'let-done (loop-let j))))
(loop-let n)
(define (loop-let* i) (let* ((j (- i 1)) (k j)) (if (< k 0) 'let*-done (loop-let* k))))
(loop-let* n)
(define (loop-letrec i) (letrec ((j (- i 1))) (if (< j 0) 'letrec-done (loop-letrec j))))
(loop-letrec n)
(define (loop-named i) (let lp ((k i)) (if (= k 0) 'named-done (lp (- k 1)))))
(loop-named n)
(define (loop-apply i) (if (= i 0) 'apply-done (apply loop-apply (list (- i 1)))))
(loop-apply n)
(define (loop-lambda i) (if (= i 0) 'lambda-done ((lambda (j) (loop-lambda j)) (- i 1))))
(loop-lambda n)
(define (loop-body i) (define j (- i 1)) (if (< j 0) 'body-done (loop-body j)))
(loop-body n)
(define (loop-nested i) (if (= i 0) 'nested-done (let ((a 1)) (let* ((b 2)) (begin (cond (#t (and #t (or #f (if #t (loop-nested (- i 1)) 'no))))))))))
(loop-nested n)
(define (loop-mutual-a i) (if (= i 0) 'mutual-done (loop-mutual-b (- i 1))))
(define (loop-mutual-b i) (cond ((= i 0) 'mutual-done) (else (loop-mutual-a (- i 1)))))
(loop-mutual-a n)
(define (loop-closure i) (if (= i 0) 'closure-done ((let ((f loop-closure)) f) (- i 1))))
(loop-closure n)
(define (loop-named-outer i)
  (let outer ((k i))
    (if (= k 0) 'named-outer-done
        (let inner ((m 2))
          (if (= m 0) (outer (- k 1)) (inner (- m 1)))))))
(loop-named-outer n)
""" % N, ['if-done', 'if-else-done', 'cond-done', 'cond-mid-done', '#t', '#t', 'begin-done', str(N),
          'let-done', 'let*-done', 'letrec-done', 'named-done', 'apply-done', 'lambda-done',
          'body-done', 'nested-done', 'mutual-done', 'closure-done', 'named-outer-done'])

add('tail_apply_or_cond_1e6', """(define (loop-apply i) (if (= i 0) 'apply-done (apply loop-apply (list (- i 1)))))
(loop-apply 1000000)
(define (loop-or i) (or (= i 0) (loop-or (- i 1))))
(loop-or 1000000)
(define (loop-cond i) (cond ((= i 0) 'cond-done) (else (loop-cond (- i 1)))))
(loop-cond 1000000)
""", ['apply-done', '#t', 'cond-done'])

add('tail_loop_3e6', """(let loop ((i 0) (acc 0))
  (if (= i 3000000) acc (loop (+ i 1) (+ acc i))))
""", [str(sum(range(3000000)))])

add('fib_27', """(define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
(fib 27)
""", [str(fib(27))])

add('string_build', """(define (repeat s n) (let loop ((i 0) (acc "")) (if (= i n) acc (loop (+ i 1) (string-append acc s)))))
(string-length (repeat "abcde" 5000))
(define (digits n) (let loop ((i 0) (acc "")) (if (= i n) acc (loop (+ i 1) (string-append acc (number->string (remainder i 10)))))))
(string-length (digits 3000))
(define big (digits 3000))
(equal? (string-append big big) (digits 6000))
(define (join l sep)
  (cond ((null? l) "")
        ((null? (cdr l)) (car l))
        (else (string-append (car l) sep (join (cdr l) sep)))))
(join '("a" "b" "c") ", ")
(join '() ", ")
(join '("solo") ", ")
(define (range a b) (let loop ((i b) (acc '())) (if (< i a) acc (loop (- i 1) (cons i acc)))))
(define (map f l) (if (null? l) '() (cons (f (car l)) (map f (cdr l)))))
(string-length (join (map number->string (range 1 2000)) ","))
(display (join (map number->string (range 1 30)) " ")) (newline)
(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
(string-length (join (map (lambda (i) (number->string (fact i))) (range 0 200)) ""))
(define (str-rev-words l) (if (null? l) "" (string-append (str-rev-words (cdr l)) (symbol->string (car l)) " ")))
(str-rev-words '(one two three four))
""", ['25000', '3000', '#t', '"a, b, c"', '""', '"solo"',
      str(len(','.join(str(i) for i in range(1, 2001)))), ' '.join(str(i) for i in range(1, 31)),
      str(sum(len(str(math.factorial(i))) for i in range(201))), '"four three two one "'])

add('mini_interpreter', """(define (cadr x) (car (cdr x)))
(define (caddr x) (car (cdr (cdr x))))
(define (cadddr x) (car (cdr (cdr (cdr x)))))
(define (map f l) (if (null? l) '() (cons (f (car l)) (map f (cdr l)))))
(define (lookup var env)
  (cond ((null? env) (error "unbound" var))
        ((eq? (car (car env)) var) (cdr (car env)))
        (else (lookup var (cdr env)))))
(define (meval e env)
  (cond ((number? e) e)
        ((boolean? e) e)
        ((symbol? e) (lookup e env))
        ((eq? (car e) 'quote) (cadr e))
        ((eq? (car e) 'lambda) (list 'closure (cadr e) (caddr e) env))
        ((eq? (car e) 'if)
         (if (meval (cadr e) env) (meval (caddr e) env) (meval (cadddr e) env)))
        ((eq? (car e) 'let)
         (meval (caddr e)
                (bind (map car (cadr e)) (map (lambda (b) (meval (cadr b) env)) (cadr e)) env)))
        (else (mapply (meval (car e) env) (map (lambda (x) (meval x env)) (cdr e))))))
(define (bind params args env)
  (if (null? params) env
      (cons (cons (car params) (car args)) (bind (cdr params) (cdr args) env))))
(define (mapply f args)
  (cond ((procedure? f) (apply f args))
        ((and (pair? f) (eq? (car f) 'closure))
         (meval (caddr f) (bind (cadr f) args (cadddr f))))
        (else (error "not applicable" f))))
(define genv (list (cons '+ +) (cons '- -) (cons '* *) (cons '= =) (cons '< <)
                   (cons 'cons cons) (cons 'car car) (cons 'cdr cdr) (cons 'null? null?)))
(meval '((lambda (x) (* x x)) 7) genv)
(meval '(((lambda (f) (lambda (n) (f f n)))
          (lambda (self n) (if (= n 0) 1 (* n (self self (- n 1))))))
         20) genv)
(meval '(let ((x 3) (y 4)) (+ (* x x) (* y y))) genv)
(meval '(let ((Y (lambda (f) ((lambda (x) (f (lambda (v) ((x x) v)))) (lambda (x) (f (lambda (v) ((x x) v))))))))
          ((Y (lambda (fib) (lambda (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))))) 15))
       genv)
(meval '((lambda (l) (car (cdr l))) (quote (a b c))) genv)
(meval '(if (null? (quote ())) (quote yes) (quote no)) genv)
(meval '(lambda (x) x) genv)
(meval '((lambda (loop) (loop loop 20000 0))
         (lambda (self i acc) (if (= i 0) acc (self self (- i 1) (+ acc i)))))
       genv)
(meval 'undefined-var genv)
""", ['49', str(math.factorial(20)), '25', str(fib(15)), 'b', 'yes',
      '(closure (x) x ((+ . #<procedure>) (- . #<procedure>) (* . #<procedure>) (= . #<procedure>) (< . #<procedure>) (cons . #<procedure>) (car . #<procedure>) (cdr . #<procedure>) (null? . #<procedure>)))',
      str(sum(range(20001))), 'error: user-error'])

add('church_numerals', """(define zero (lambda (f) (lambda (x) x)))
(define (succ n) (lambda (f) (lambda (x) (f ((n f) x)))))
(define (add m n) (lambda (f) (lambda (x) ((m f) ((n f) x)))))
(define (mul m n) (lambda (f) (m (n f))))
(define (expt m n) (n m))
(define (to-int n) ((n (lambda (x) (+ x 1))) 0))
(define one (succ zero))
(define two (succ one))
(define three (add one two))
(to-int zero)
(to-int one)
(to-int three)
(to-int (mul three three))
(to-int (mul (add two three) (mul three three)))
(define (church n) (if (= n 0) zero (succ (church (- n 1)))))
(to-int (mul (church 20) (church 30)))
(to-int (expt two three))
(to-int (expt three two))
(to-int (expt (church 2) (church 10)))
(define true (lambda (a) (lambda (b) a)))
(define false (lambda (a) (lambda (b) b)))
(define (to-bool b) ((b #t) #f))
(define (is-zero n) ((n (lambda (x) false)) true))
(to-bool (is-zero zero))
(to-bool (is-zero three))
(define (pair a b) (lambda (s) ((s a) b)))
(define (fst p) (p true))
(define (snd p) (p false))
(define (pred n) (fst ((n (lambda (p) (pair (snd p) (succ (snd p))))) (pair zero zero))))
(to-int (pred (church 10)))
(to-int (pred zero))
(define (sub m n) ((n pred) m))
(to-int (sub (church 10) (church 3)))
(define (church-fact n) ((lambda (Y) ((Y (lambda (f) (lambda (n) (if (= n 0) 1 (* n (f (- n 1))))))) n)) (lambda (f) ((lambda (x) (f (lambda (v) ((x x) v)))) (lambda (x) (f (lambda (v) ((x x) v))))))))
(church-fact 10)
zero
""", ['0', '1', '3', '9', '45', '600', '8', '9', '1024', '#t', '#f', '9', '0', '7', '3628800',
      '#<procedure>'])

# ---------------------------------------------------------------------------
# Emit
# ---------------------------------------------------------------------------


def run_reference(program):
    proc = subprocess.run([sys.executable, REF], input=program.encode('utf-8'),
                          capture_output=True, timeout=300)
    if proc.returncode != 0:
        raise RuntimeError('reference crashed: ' + proc.stderr.decode('utf-8', 'replace'))
    return proc.stdout.decode('utf-8')


def normalize(text):
    return '\n'.join(line.rstrip() for line in text.split('\n')).rstrip('\n')


def main():
    os.makedirs(TESTS, exist_ok=True)
    for f in os.listdir(TESTS):
        if f.endswith('.in') or f.endswith('.out'):
            os.remove(os.path.join(TESTS, f))
    names = [c[0] for c in cases]
    assert len(names) == len(set(names)), 'duplicate test names'
    failures = 0
    for i, (name, program, expected) in enumerate(cases, 1):
        base = '%03d_%s' % (i, name)
        out = run_reference(program)
        if expected is not None and normalize(out) != normalize('\n'.join(expected)):
            failures += 1
            print('MISMATCH in %s' % base)
            exp_lines = normalize('\n'.join(expected)).split('\n')
            got_lines = normalize(out).split('\n')
            for j in range(max(len(exp_lines), len(got_lines))):
                e = exp_lines[j] if j < len(exp_lines) else '<none>'
                g = got_lines[j] if j < len(got_lines) else '<none>'
                if e != g:
                    print('  line %d: expected %r got %r' % (j + 1, e, g))
                    break
        with open(os.path.join(TESTS, base + '.in'), 'w', encoding='utf-8') as f:
            f.write(program)
        with open(os.path.join(TESTS, base + '.out'), 'w', encoding='utf-8') as f:
            f.write(out)
        print('wrote %s (%d bytes in, %d bytes out)' % (base, len(program), len(out)))
    if failures:
        print('%d test(s) disagree with their expected output' % failures)
        sys.exit(1)
    print('%d tests generated, all expected outputs confirmed' % len(cases))


if __name__ == '__main__':
    main()
