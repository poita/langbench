(ns datalog.core-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [datalog.core :as dl]))

(defn- lines [& ls] (str (str/join "\n" ls) "\n"))

(deftest transitive-closure-test
  (is (= (lines "path(1, 1)" "path(1, 2)" "path(1, 3)" "path(1, 4)" "-- 4"
                "-- 0"
                "path(1, 1)" "path(2, 2)" "path(3, 3)" "-- 3")
         (dl/run-string
          "edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
           path(X, Y) :- edge(X, Y).
           path(X, Z) :- edge(X, Y), path(Y, Z).
           ?- path(1, X). ?- path(4, X). ?- path(X, X)."))))

(deftest negation-comparison-mixed-constants-test
  (is (= (lines "sink(-2)" "sink(c)" "-- 2"
                "small(-2)" "small(5)" "-- 2"
                "reach(a, 5)" "reach(a, b)" "-- 2"
                "reach(5, 5)" "-- 1")
         (dl/run-string
          "% nodes and links
           node(a). node(b). node(c). node(5). node(-2).
           link(a, b). link(b, 5). link(5, 5).
           reach(X, Y) :- link(X, Y).
           reach(X, Z) :- reach(X, Y), link(Y, Z).
           sink(X) :- node(X), not hasout(X).
           hasout(X) :- link(X, _).
           small(X) :- node(X), X < a.
           ?- sink(X). ?- small(X). ?- reach(a, X). ?- reach(X, X)."))))

(deftest errors-test
  (testing "unstratifiable"
    (is (= "error\n" (dl/run-string "edge(1, 2). win(X) :- edge(X, Y), not win(Y). ?- win(X)."))))
  (testing "unsafe; earlier queries print nothing"
    (is (= "error\n" (dl/run-string "q(1). ?- q(X). p(X) :- q(Y). ?- p(X)."))))
  (testing "unsafe fact"
    (is (= "error\n" (dl/run-string "p(X)."))))
  (testing "check reports the reason"
    (is (= :unsafe (:error (dl/check (dl/parse "p(X) :- q(Y).")))))
    (is (= :unstratifiable (:error (dl/check (dl/parse "p(X) :- q(X), not p(X).")))))
    (is (nil? (dl/check (dl/parse "p(1).")))))
  (testing "solve throws on invalid programs"
    (is (thrown? clojure.lang.ExceptionInfo (dl/solve (dl/parse "p(X) :- q(Y).")))))
  (testing "error beats everything else"
    (is (= "error\n" (dl/run-string "p(1). ?- p(X). q(X) :- not q(X), p(X).")))))

(deftest empty-and-query-less-programs-test
  (is (= "" (dl/run-string "")))
  (is (= "" (dl/run-string "  % nothing\n")))
  (is (= "" (dl/run-string "p(1). q(X) :- p(X).")))
  (is (= "-- 0\n" (dl/run-string "?- nothing(X).")))
  (is (= "-- 0\n" (dl/run-string "p(1). ?- p(2)."))))

(deftest ordering-test
  (is (= (lines "o(-10)" "o(-1)" "o(0)" "o(7)" "o(a)" "o(a0)" "o(a_)" "o(a_b)" "o(aa)" "o(ab)" "o(b)" "-- 11")
         (dl/run-string "o(b). o(ab). o(aa). o(a_b). o(a_). o(a0). o(a). o(7). o(0). o(-1). o(-10). ?- o(X)."))))

(deftest comparison-operators-test
  (let [run #(dl/run-string (str "n(1). n(2). n(3). n(x). n(y). " % " ?- r(X)."))]
    (is (= (lines "r(1)" "r(2)" "-- 2") (run "r(X) :- n(X), X < 3.")))
    (is (= (lines "r(1)" "r(2)" "r(3)" "-- 3") (run "r(X) :- n(X), X <= 3.")))
    (is (= (lines "r(y)" "-- 1") (run "r(X) :- n(X), X > x.")))
    (is (= (lines "r(x)" "r(y)" "-- 2") (run "r(X) :- n(X), X >= x.")))
    (is (= (lines "r(x)" "-- 1") (run "r(X) :- n(X), X = x.")))
    (is (= (lines "r(2)" "-- 1") (run "r(X) :- n(X), X != 1, X != 3, X != x, X != y.")))
    (is (= (lines "r(5)" "-- 1") (run "r(5) :- 1 < a.")))
    (is (= "-- 0\n" (run "r(5) :- a < 1.")))
    (testing "integer never equals identifier"
      (is (= "-- 0\n" (run "r(X) :- n(X), n(Y), X = Y, X < 1."))))))

(deftest query-patterns-test
  (let [facts "e(1, 1). e(1, 2). e(2, 2). e(a, a). e(a, 1). "
        q #(dl/run-string (str facts "?- " % "."))]
    (is (= (lines "e(1, 1)" "e(2, 2)" "e(a, a)" "-- 3") (q "e(X, X)")))
    (is (= (lines "e(1, 1)" "e(1, 2)" "-- 2") (q "e(1, _)")))
    (is (= (lines "e(1, 1)" "e(1, 2)" "e(2, 2)" "e(a, 1)" "e(a, a)" "-- 5") (q "e(_, _)")))
    (testing "wrong arity is another, empty, predicate"
      (is (= "-- 0\n" (q "e(1)"))))))

(deftest same-name-different-arity-test
  (is (= (lines "r(1)" "-- 1" "r(1, 2)" "-- 1")
         (dl/run-string "r(1). r(X, Y) :- r(X), s(Y). s(2). ?- r(X). ?- r(X, Y)."))))

(deftest non-linear-recursion-test
  (testing "every recursive body position uses the delta"
    (is (= (lines "link(1, 2)" "link(1, 3)" "link(1, 4)" "link(1, 5)" "-- 4")
           (dl/run-string
            "link(1, 2). link(2, 3). link(3, 4). link(4, 5).
             link(X, Z) :- link(X, Y), link(Y, Z).
             ?- link(1, X).")))
    (is (= 21 (count (dl/query (dl/solve (dl/parse
                                          "l(1,2). l(2,3). l(3,4). l(4,5). l(5,6). l(6,7).
                                           l(X,Z) :- l(X,Y), l(Y,Z)."))
                               "l" ['X 'Y])))
        "the closure of a 7-node chain has 7*6/2 pairs")))

(deftest mutual-recursion-test
  (is (= (lines "even(0)" "even(2)" "even(4)" "-- 3" "odd(1)" "odd(3)" "-- 2")
         (dl/run-string
          "succ(0, 1). succ(1, 2). succ(2, 3). succ(3, 4).
           even(0).
           odd(Y) :- even(X), succ(X, Y).
           even(Y) :- odd(X), succ(X, Y).
           ?- even(X). ?- odd(X)."))))

(deftest stratified-negation-chain-test
  (is (= "-- 0\n"
         (dl/run-string
          "n(1). n(2). n(3). a(1).
           b(X) :- n(X), not a(X).
           c(X) :- n(X), not b(X), X != 1. ?- c(X)."))
      "c = a = {1}, and 1 is excluded by the comparison")
  (is (= (lines "c(1)" "-- 1")
         (dl/run-string
          "n(1). n(2). n(3). a(1).
           b(X) :- n(X), not a(X).
           c(X) :- n(X), not b(X). ?- c(X)."))))

(deftest facts-and-rules-share-a-predicate-test
  (is (= (lines "p(1)" "p(2)" "-- 2")
         (dl/run-string "p(1). p(X) :- q(X). p(2). q(2). q(1). ?- p(X)."))))

(deftest library-api-test
  (let [model (dl/solve (dl/parse "edge(a, b). edge(b, c).
                                   path(X, Y) :- edge(X, Y).
                                   path(X, Z) :- edge(X, Y), path(Y, Z)."))]
    (is (= [["a" "b"] ["a" "c"]] (dl/query model "path" ["a" 'X])))
    (is (= [["a" "c"]] (dl/query model "path" ["a" "c"])))
    (is (= [] (dl/query model "path" ["zzz" 'X])) "unknown constants match nothing")
    (is (= [] (dl/query model "nope" ['X])))
    (is (= [{:pred "q" :args [1 'X]}]
           (dl/query-clauses (dl/parse "p(1). ?- q(1, X)."))))))
