(ns datalog.analysis-test
  (:require [clojure.test :refer [deftest is testing]]
            [datalog.analysis :as an]
            [datalog.parser :as p]))

(defn- rules [text] (:rules (p/parse-program text)))

(defn- thrown-type [f]
  (try (f) nil (catch clojure.lang.ExceptionInfo e (:type (ex-data e)))))

(deftest safety-test
  (testing "safe programs"
    (is (nil? (thrown-type #(an/check-safety!
                             (rules "q(1). p(X) :- q(X), not r(X), X < 3. s(a) :- not r(b)."))))))
  (testing "unsafe rules"
    (doseq [bad ["p(X)."
                 "p(_)."
                 "p(X) :- q(Y)."
                 "p(X) :- q(X), not r(Y)."
                 "p(X) :- q(X), not r(_)."
                 "p(Y) :- q(X), X = Y."
                 "p(X) :- q(X), Y = 5."
                 "p(X) :- q(X), X < _."
                 "p(X) :- not q(X), X = 1."]]
      (is (= :datalog/unsafe-rule (thrown-type #(an/check-safety! (rules bad)))) bad))))

(deftest stratify-test
  (testing "components come dependencies first"
    (let [comps (an/stratify (rules "p(X) :- q(X). q(X) :- r(X), not s(X). r(1)."))
          pos (fn [k] (.indexOf ^java.util.List (vec comps) [k]))]
      (is (< (pos ["r" 1]) (pos ["q" 1]) (pos ["p" 1])))
      (is (< (pos ["s" 1]) (pos ["q" 1])))))
  (testing "mutual positive recursion forms one component"
    (is (some #(= #{["a" 1] ["b" 1]} (set %))
              (an/stratify (rules "a(X) :- b(X). b(X) :- a(X). a(1).")))))
  (testing "negation on a cycle"
    (doseq [bad ["win(X) :- e(X, Y), not win(Y)."
                 "p(X) :- q(X), not r(X). r(X) :- p(X)."
                 "a(X) :- b(X). b(X) :- c(X). c(X) :- d(X), not a(X)."]]
      (is (= :datalog/not-stratifiable (thrown-type #(an/stratify (rules bad)))) bad)))
  (testing "same name at different arities are different predicates"
    (is (vector? (an/stratify (rules "p(X) :- q(X), not p(X, X)."))))))
