(ns datalog.core-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [datalog.core :as dl]))

(defn- run [text] (dl/format-answers (dl/run-program text)))

(defn- run-or-error [text]
  (try (run text)
       (catch clojure.lang.ExceptionInfo e
         (if (dl/error? e) "error\n" (throw e)))))

(deftest transitive-closure-test
  (is (= (str/join "\n" ["path(1, 1)" "path(1, 2)" "path(1, 3)" "path(1, 4)" "-- 4"
                         "-- 0"
                         "path(1, 1)" "path(2, 2)" "path(3, 3)" "-- 3" ""])
         (run "edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
               path(X, Y) :- edge(X, Y).
               path(X, Z) :- edge(X, Y), path(Y, Z).
               ?- path(1, X).
               ?- path(4, X).
               ?- path(X, X)."))))

(deftest negation-comparison-mixed-constants-test
  (is (= (str/join "\n" ["sink(-2)" "sink(c)" "-- 2"
                         "small(-2)" "small(5)" "-- 2"
                         "reach(a, 5)" "reach(a, b)" "-- 2"
                         "reach(5, 5)" "-- 1" ""])
         (run "% nodes and links
               node(a). node(b). node(c). node(5). node(-2).
               link(a, b). link(b, 5). link(5, 5).
               reach(X, Y) :- link(X, Y).
               reach(X, Z) :- reach(X, Y), link(Y, Z).
               sink(X) :- node(X), not hasout(X).
               hasout(X) :- link(X, _).
               small(X) :- node(X), X < a.
               ?- sink(X). ?- small(X). ?- reach(a, X). ?- reach(X, X)."))))

(deftest errors-test
  (is (= "error\n" (run-or-error "edge(1, 2). win(X) :- edge(X, Y), not win(Y). ?- win(X).")))
  (is (= "error\n" (run-or-error "q(1). ?- q(X). p(X) :- q(Y). ?- p(X).")))
  (is (= "error\n" (run-or-error "p(X).")))
  (is (= "" (run-or-error "p(1).")) "no queries, no output")
  (is (= "" (run-or-error "  % just a comment\n"))))

(deftest ordering-test
  (testing "integers before identifiers; identifiers by strcmp"
    (is (= "k(-3)\nk(0)\nk(12)\nk(a)\nk(a0)\nk(a_)\nk(a_b)\nk(aa)\nk(ab)\nk(b)\n-- 10\n"
           (run "k(b). k(ab). k(aa). k(a_b). k(a_). k(a0). k(a). k(12). k(0). k(-3). ?- k(X).")))
    (is (= "t(1, 2)\nt(1, b)\nt(a, 1)\n-- 3\n"
           (run "t(a, 1). t(1, b). t(1, 2). ?- t(X, Y).")))))

(deftest comparison-semantics-test
  (is (= "s(1)\ns(a)\n-- 2\n"
         (run "v(1). v(a). v(2). v(b).
               s(X) :- v(X), X != 2, X != b.
               ?- s(X).")))
  (is (= "g(5, a)\n-- 1\n"
         (run "v(5). v(a). g(X, Y) :- v(X), v(Y), X < Y, Y <= a, X >= 5, Y > X, X != Y. ?- g(X, Y).")))
  (is (= "z(1)\n-- 1\n" (run "z(1) :- 1 < 2. y(1) :- 2 < 1. ?- z(X).")))
  (is (= "-- 0\n" (run "w(1) :- 1 = a. ?- w(X)."))))

(deftest query-patterns-test
  (let [text "e(1, 1). e(1, 2). e(2, 2). e(3, 1).\n"]
    (is (= "e(1, 1)\ne(2, 2)\n-- 2\n" (run (str text "?- e(X, X)."))))
    (is (= "e(1, 1)\ne(1, 2)\n-- 2\n" (run (str text "?- e(1, _)."))))
    (is (= "e(1, 1)\ne(3, 1)\n-- 2\n" (run (str text "?- e(_, 1)."))))
    (is (= "e(2, 2)\n-- 1\n" (run (str text "?- e(2, 2)."))))
    (is (= "-- 0\n" (run (str text "?- e(9, 9)."))))
    (is (= "-- 0\n" (run (str text "?- nosuch(X)."))))
    (is (= "-- 0\n" (run (str text "?- e(X, Y, Z)."))))))

(deftest nonlinear-recursion-test
  (testing "tuples derived in earlier rounds join in every recursive position"
    (is (= 15 (count (dl/query (dl/solve "l(1,2). l(2,3). l(3,4). l(4,5). l(5,6).
                                         l(X,Z) :- l(X,Y), l(Y,Z).")
                               "l(X, Y)")))))
  (testing "mutual recursion"
    (is (= [[0] [2] [4]]
           (dl/query (dl/solve "num(0). succ(0,1). succ(1,2). succ(2,3). succ(3,4).
                                even(0).
                                even(Y) :- odd(X), succ(X,Y).
                                odd(Y) :- even(X), succ(X,Y).")
                     "even(X)")))))

(deftest model-api-test
  (let [model (dl/solve (dl/parse-program "p(1). p(2). q(X) :- p(X), not r(X). r(2)."))]
    (is (= [[1]] (dl/query model "q(X)")))
    (is (= [[1] [2]] (dl/query model {:pred "p" :args ['X]})))
    (is (= [] (dl/query model "p(99)")) "unknown constant")))

(deftest facts-and-rules-same-predicate-test
  (is (= "p(1)\np(2)\np(3)\n-- 3\n"
         (run "p(1). q(2). p(X) :- q(X). p(3). p(3). ?- p(X)."))))
