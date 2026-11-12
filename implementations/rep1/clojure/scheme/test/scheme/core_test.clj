(ns scheme.core-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [scheme.core :as scheme]))

(defn- run [& lines] (scheme/run-string (str/join "\n" lines)))

(deftest spec-examples
  (is (= "2432902008176640000\ndone\n(1 \"two\" (3 . 4) #t)\n(1 . 2)\n"
         (run "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))"
              "(fact 20)"
              "(display \"done\") (newline)"
              "'(1 \"two\" (3 . 4) #t)"
              "(cons 1 2)")))
  (is (= "1\n2\n499999500000\nerror: unbound-variable\n"
         (run "(define (make-counter) (let ((n 0)) (lambda () (set! n (+ n 1)) n)))"
              "(define c (make-counter))"
              "(c) (c)"
              "(let loop ((i 0) (acc 0)) (if (= i 1000000) acc (loop (+ i 1) (+ acc i))))"
              "(map (lambda (x) (* x x)) '(1 2 3))")))
  (is (= "a(1 b c)\n(#<void> #<procedure>)\nerror: division-by-zero\n"
         (run "(display \"a\") (display (list 1 \"b\" 'c)) (newline)"
              "(if #f #f)" "(list (if #f #f) car)" "(quotient 1 0)" "(display \"never\")"))))

(deftest empty-and-void
  (is (= "" (run "")))
  (is (= "" (run "(define x 1) (set! x 2)")))
  (is (= "\n" (run "(define x 1) (set! x 2) (newline)"))))

(deftest printing
  (is (= "\"a\\\"b\\\\\\n\\t\"\n" (run "\"a\\\"b\\\\\\n\\t\"")))
  (is (= "a\"b" (run "(display \"a\\\"b\")")))
  (is (= "(x y)" (run "(display '(\"x\" y))")))
  (is (= "(quote a)\n" (run "''a")))
  (is (= "((1 2) (3 . 4) ())\n" (run "'((1 2) (3 . 4) ())")))
  (is (= "#<procedure>\n" (run "car")))
  (is (= "-12\n" (run "-12"))))

(deftest errors
  (testing "categories"
    (is (= "error: unbound-variable\n" (run "foo")))
    (is (= "error: unbound-variable\n" (run "(set! nope 1)")))
    (is (= "error: type-error\n" (run "(car '())")))
    (is (= "error: type-error\n" (run "(< 2 1 \"x\")")))
    (is (= "error: type-error\n" (run "(5 3)")))
    (is (= "error: type-error\n" (run "(apply + 1 2)")))
    (is (= "error: arity-error\n" (run "((lambda (x) x))")))
    (is (= "error: arity-error\n" (run "((lambda (x) x) 1 2)")))
    (is (= "error: arity-error\n" (run "(cons 1)")))
    (is (= "error: division-by-zero\n" (run "(remainder 5 0)")))
    (is (= "error: user-error\n" (run "(error \"boom\" 1 2)"))))
  (testing "output is kept and the error text follows it directly"
    (is (= "xyerror: arity-error\n" (run "(car (display \"x\") (display \"y\"))")))
    (is (= "1\nerror: type-error\n" (run "1 (car 1) 2")))
    (is (= "xerror: unbound-variable\n" (run "(set! zz (display \"x\"))")))))

(deftest evaluation-order
  (is (= "abc(#<void> #<void> #<void>)\n" (run "(list (display \"a\") (display \"b\") (display \"c\"))")))
  (is (= "fab(#<void> #<void>)\n" (run "((begin (display \"f\") list) (display \"a\") (display \"b\"))")))
  (is (= "12" (run "(let ((a (display 1)) (b (display 2))) a)"))))

(deftest scoping
  (testing "named let: name invisible to inits, visible in body"
    (is (= "outer\n" (run "(define lp 'outer) (let lp ((x lp)) x)")))
    (is (= "3\n" (run "(let lp ((i 0)) (if (< i 3) (lp (+ i 1)) i))"))))
  (testing "let* frames and internal defines"
    (is (= "2\n" (run "(let* ((a 1) (b (+ a 1))) (define c b) c)")))
    (is (= "error: unbound-variable\n"
           (run "(let* ((f (lambda () d)) (x 1)) (define d 2) (f))"))))
  (testing "letrec"
    (is (= "#t\n" (run "(letrec ((ev? (lambda (n) (if (= n 0) #t (od? (- n 1)))))"
                       "         (od? (lambda (n) (if (= n 0) #f (ev? (- n 1))))))"
                       "  (ev? 10))"))))
  (testing "variadic and dotted parameters"
    (is (= "(1 2 3)\n" (run "((lambda args args) 1 2 3)")))
    (is (= "(1 (2 3))\n" (run "((lambda (a . r) (list a r)) 1 2 3)")))
    (is (= "error: arity-error\n" (run "((lambda (a b . r) a) 1)"))))
  (testing "define in the innermost frame"
    (is (= "2\n1\n" (run "(define x 1) (define (f) (define x 2) x) (f) x")))))

(deftest cond-and-or
  (is (= "7\n" (run "(cond (#f 1) (7))")))
  (is (= "" (run "(cond (#f 1))")))
  (is (= "#t\n#f\n3\n#f\n" (run "(and) (or) (and 1 2 3) (or #f #f)")))
  (is (= "2\n" (run "(cond (#f 1) (else 2))"))))

(deftest equivalence
  (is (= "#t\n#f\n#t\n#f\n" (run "(eq? 100000000000000000000 100000000000000000000)"
                                  "(eq? (list 1) (list 1))"
                                  "(equal? '(1 (2 \"x\")) (list 1 (list 2 \"x\")))"
                                  "(equal? 1 \"1\")"))))

(deftest tail-calls-and-deep-recursion
  (is (= "done\n" (run "(define (loop i) (if (= i 0) 'done (loop (- i 1)))) (loop 1000000)")))
  (is (= "done\n" (run "(define (loop i) (if (= i 0) 'done (apply loop (list (- i 1))))) (loop 300000)")))
  (is (= "10000\n" (run "(define (count n) (if (= n 0) 0 (+ 1 (count (- n 1))))) (count 10000)"))))

(deftest library-api
  (let [interp (scheme/make-interpreter (java.io.StringWriter.))]
    (scheme/eval-string interp "(define (sq x) (* x x))")
    (is (= 144 (scheme/eval-string interp "(sq 12)")))
    (is (= :division-by-zero
           (try (scheme/eval-string interp "(quotient 1 0)")
                (catch Exception e (scheme/error-category e)))))))
