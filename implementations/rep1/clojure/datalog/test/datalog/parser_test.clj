(ns datalog.parser-test
  (:require [clojure.test :refer [deftest is testing]]
            [datalog.parser :as p]))

(deftest tokenize-test
  (testing "longest match and comments"
    (is (= [[:var "X"] [:punct "<"] [:int -1]] (p/tokenize "X<-1")))
    (is (= [[:var "X"] [:punct "<="] [:int 1]] (p/tokenize "X<=1")))
    (is (= [[:ident "a"] [:punct ":-"] [:not "not"] [:ident "nothing"]]
           (p/tokenize "a :- not % comment\n nothing"))))
  (testing "identifier vs keyword vs anonymous"
    (is (= [[:ident "not_x"] [:anon "_"] [:var "Foo_1"]] (p/tokenize "not_x _ Foo_1")))))

(deftest parse-program-test
  (testing "facts, rules and queries keep source order"
    (is (= {:rules [{:head {:pred "e" :args [1 :b]} :body []}
                    {:head {:pred "p" :args ['X]}
                     :body [{:op :pos :atom {:pred "e" :args ['X '_]}}
                            {:op :neg :atom {:pred "q" :args ['X]}}
                            {:op :cmp :cmp :!= :left 'X :right -5}]}]
            :queries [{:pred "p" :args ['Y]}]}
           (p/parse-program "?- p(Y). e(1, b). p(X) :- e(X, _), not q(X), X != -5."))))
  (testing "a comparison may start with a constant identifier"
    (is (= {:op :cmp :cmp :< :left :a :right 'X}
           (-> (p/parse-program "p(X) :- q(X), a < X.") :rules first :body second))))
  (testing "empty and comment-only programs"
    (is (= {:rules [] :queries []} (p/parse-program "  % nothing\n\t")))))

(deftest parse-errors-test
  (doseq [bad ["p(1)" "p(1) :- ." "p(" "?- p(1)" "p(1) q(2)." "p(1) :- X ."]]
    (is (= :datalog/parse-error
           (try (p/parse-program bad) nil
                (catch clojure.lang.ExceptionInfo e (:type (ex-data e)))))
        bad)))

(deftest parse-atom-test
  (is (= {:pred "path" :args [1 'X :a]} (p/parse-atom "path(1, X, a)"))))
