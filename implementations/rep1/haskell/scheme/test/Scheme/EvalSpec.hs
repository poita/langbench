module Scheme.EvalSpec (spec) where

import Test.Hspec

import Scheme (runProgramToString)

-- | Run a program and compare its complete output.
(==>) :: String -> String -> Expectation
src ==> expected = runProgramToString src `shouldReturn` expected

infix 1 ==>

spec :: Spec
spec = do
  describe "output" $ do
    it "prints the values of top-level forms but not void" $
      "(define x 1) x (display \"a\") (newline) '(1 \"two\" (3 . 4) #t) (if #f #f)"
        ==> "1\na\n(1 \"two\" (3 . 4) #t)\n"
    it "shows void inside lists" $
      "(list (if #f #f) car)" ==> "(#<void> #<procedure>)\n"
    it "does not print an empty program" $ "" ==> ""
    it "displays strings raw at any depth" $
      "(display '(\"x\" y)) (display \"a\\\"b\")" ==> "(x y)a\"b"

  describe "special forms" $ do
    it "handles define/set! and closures" $
      "(define (mk) (let ((n 0)) (lambda () (set! n (+ n 1)) n))) (define c (mk)) (c) (c)"
        ==> "1\n2\n"
    it "supports variadic lambdas" $
      "((lambda (a . r) (list a r)) 1 2 3) ((lambda r r) 1 2) (apply + 1 2 '(3 4))"
        ==> "(1 (2 3))\n(1 2)\n10\n"
    it "scopes named let: the name is invisible to its inits" $
      "(define loop 5) (let loop ((i loop)) (if (= i 0) 'done (loop (- i 1))))" ==> "done\n"
    it "puts let* defines in the innermost frame" $
      "(define f (let* ((a 1) (g (lambda () a)) (b 2)) (define a 10) g)) (f)" ==> "1\n"
    it "evaluates letrec inits in order within the new frame" $
      "(letrec ((e (lambda (n) (if (= n 0) #t (o (- n 1))))) (o (lambda (n) (if (= n 0) #f (e (- n 1)))))) (e 10))"
        ==> "#t\n"
    it "handles cond, and, or" $
      "(cond (#f 1) (2)) (cond (#f 1)) (and) (or) (and 1 2) (or #f 3) (cond (else 9))"
        ==> "2\n#t\n#f\n2\n3\n9\n"
    it "defines inside bodies" $
      "(define (f) (define a 1) (define (g) (+ a 1)) (g)) (f)" ==> "2\n"

  describe "evaluation order" $ do
    it "evaluates operator then operands left to right" $
      "(define (t x) (display x) x) ((begin (t 1) +) (t 2) (t 3))" ==> "1235\n"

  describe "primitives" $ do
    it "does bignum arithmetic" $
      "(* 4294967296 4294967296 4294967296) (- (+ 9223372036854775807 1) 1) (quotient (* 99999999999 99999999999) 99999999999)"
        ==> "79228162514264337593543950336\n9223372036854775807\n99999999999\n"
    it "truncates quotient and remainder toward zero" $
      "(quotient -7 2) (remainder -7 2) (remainder 7 -2)" ==> "-3\n-1\n1\n"
    it "compares chains" $
      "(< 1 2 3) (< 1 3 2) (= 1 1 1) (>= 3 3 2)" ==> "#t\n#f\n#t\n#t\n"
    it "distinguishes eq? and equal?" $
      "(eq? 'a 'a) (eq? '(1) '(1)) (equal? '(1 (2 \"x\")) '(1 (2 \"x\"))) (eq? 100000000000000000000 100000000000000000000)"
        ==> "#t\n#f\n#t\n#t\n"
    it "converts strings and symbols" $
      "(string-append \"a\" \"b\") (string-length \"hello\") (number->string -12) (symbol->string 'foo)"
        ==> "\"ab\"\n5\n\"-12\"\n\"foo\"\n"

  describe "errors" $ do
    it "reports unbound variables" $ "(display \"x\") foo (display \"y\")" ==> "xerror: unbound-variable\n"
    it "reports set! of an unbound name after evaluating the value" $
      "(set! nope (display \"v\"))" ==> "verror: unbound-variable\n"
    it "reports type errors" $ do
      "(car '())" ==> "error: type-error\n"
      "(< 2 1 \"x\")" ==> "error: type-error\n"
      "(1 2)" ==> "error: type-error\n"
      "(apply + 1 '(2 . 3))" ==> "error: type-error\n"
    it "reports arity errors after evaluating operands" $ do
      "(car (display \"x\") (display \"y\"))" ==> "xyerror: arity-error\n"
      "((lambda (a b) a) 1)" ==> "error: arity-error\n"
      "((lambda (a) a) 1 2)" ==> "error: arity-error\n"
      "((lambda (a b . r) a) 1)" ==> "error: arity-error\n"
    it "reports division by zero" $
      "(quotient 1 0)" ==> "error: division-by-zero\n"
    it "reports user errors and stops" $
      "(error \"boom\" 1 2) (display \"never\")" ==> "error: user-error\n"

  describe "tail calls and deep recursion" $ do
    it "runs a million-iteration named let" $
      "(let loop ((i 0) (acc 0)) (if (= i 1000000) acc (loop (+ i 1) (+ acc i))))"
        ==> "499999500000\n"
    it "runs tail loops through apply, or, cond, and, begin" $
      "(define (a n) (if (= n 0) 'a (apply a (list (- n 1)))))\
      \(define (o n) (or #f (if (= n 0) 'o (o (- n 1)))))\
      \(define (c n) (cond ((= n 0) 'c) (else (c (- n 1)))))\
      \(define (d n) (and #t (if (= n 0) 'd (d (- n 1)))))\
      \(define (b n) (begin 1 (if (= n 0) 'b (b (- n 1)))))\
      \(list (a 300000) (o 300000) (c 300000) (d 300000) (b 300000))"
        ==> "(a o c d b)\n"
    it "supports non-tail recursion 10000 deep" $
      "(define (sum n) (if (= n 0) 0 (+ n (sum (- n 1))))) (sum 10000)" ==> "50005000\n"
