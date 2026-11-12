(ns datalog.parser-test
  (:require [clojure.test :refer [deftest is testing]]
            [datalog.parser :as parser]))

(deftest tokenize-test
  (testing "longest match and negative integers"
    (is (= [[:var "X" 0] [:punct :< 1] [:int -1 2]] (parser/tokenize "X<-1")))
    (is (= [:<= :>= :!= :=] (map second (parser/tokenize "<= >= != =")))))
  (testing "comments and whitespace"
    (is (= [[:ident "a" 8]] (parser/tokenize "% hi\r\n\t a % x"))))
  (testing "keywords and anonymous variables"
    (is (= [:not :ident :ident :anon :var]
           (map first (parser/tokenize "not nothing not_x _ X_1"))))))

(deftest parse-fact-and-rule-test
  (is (= [{:type :rule :head {:pred "p" :args [1 "a" -7]} :body []}]
         (parser/parse-program "p(1, a, -7).")))
  (is (= [{:type :rule
           :head {:pred "p" :args ['X]}
           :body [{:kind :atom :negated? false :pred "q" :args ['X '_1]}
                  {:kind :atom :negated? true :pred "r" :args ['X]}
                  {:kind :cmp :op :<= :left 'X :right 5}
                  {:kind :cmp :op :!= :left "a" :right 'X}]}]
         (parser/parse-program
          "p(X) :- q(X, _), not r(X), X <= 5, a != X."))))

(deftest parse-query-test
  (is (= [{:type :query :atom {:pred "p" :args [1 '_1 '_2]}}]
         (parser/parse-program "?- p(1, _, _)."))))

(deftest anonymous-variables-are-distinct-test
  (let [[{[_ a b] :args}] (map :atom (parser/parse-program "?- p(X, _, _)."))]
    (is (not= a b))))

(deftest layout-test
  (is (= 3 (count (parser/parse-program "a(1).b(2). % c\n c(3)\n.")))
      "clauses may share lines and span lines")
  (is (= [] (parser/parse-program "  % only a comment\n"))))

(deftest malformed-input-test
  (doseq [bad ["p(" "p(X) :- ." "p(1)" "?- p(1)" "p(1) :- q(1) r(2)." "p(!)." "p :- q."]]
    (is (thrown-with-msg? clojure.lang.ExceptionInfo #"parse error"
                          (parser/parse-program bad))
        bad)))
