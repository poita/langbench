(ns datalog.analysis-test
  (:require [clojure.test :refer [deftest is testing]]
            [datalog.analysis :as analysis]
            [datalog.parser :as parser]))

(defn- program [text] (parser/parse-program text))

(deftest safety-test
  (testing "safe rules"
    (is (empty? (analysis/unsafe-rules (program "p(a). p(X) :- q(X, _), not r(X), X < 3."))))
    (is (empty? (analysis/unsafe-rules (program "p(a) :- 1 < 2, not q(a).")))))
  (testing "unsafe rules"
    (doseq [text ["p(X)." "p(_)." "p(X) :- q(Y)." "p(X) :- q(X), not r(X, Y)."
                  "p(X) :- q(X), Y = 5." "p(Y) :- q(X), X = Y." "p(X) :- q(X), not r(_)."
                  "p(X) :- q(X), X < _." "p(X) :- not q(X)."]]
      (is (= 1 (count (analysis/unsafe-rules (program text)))) text))))

(deftest stratify-test
  (testing "components come in dependency order"
    (let [strata (analysis/stratify
                  (program "b(X) :- a(X). c(X) :- b(X), not d(X). d(X) :- a(X)."))
          pos (into {} (for [[i comp] (map-indexed vector strata), p comp] [p i]))]
      (is (< (pos ["a" 1]) (pos ["b" 1]) (pos ["c" 1])))
      (is (< (pos ["d" 1]) (pos ["c" 1])))))
  (testing "mutual positive recursion shares a component"
    (let [strata (analysis/stratify (program "e(X) :- o(X). o(X) :- e(X)."))]
      (is (some #(= #{["e" 1] ["o" 1]} (set %)) strata))))
  (testing "negative cycles are rejected"
    (is (nil? (analysis/stratify (program "w(X) :- m(X, Y), not w(Y)."))))
    (is (nil? (analysis/stratify (program "p(X) :- q(X), not r(X). r(X) :- s(X), p(X)."))))
    (is (nil? (analysis/stratify (program "p(X) :- q(X), not p(X)."))))
    (is (some? (analysis/stratify (program "p(X) :- q(X), not r(X). r(X) :- q(X).")))))
  (testing "predicates are identified by name and arity"
    (is (some? (analysis/stratify (program "r(X) :- q(X), not r(X, X)."))))))
