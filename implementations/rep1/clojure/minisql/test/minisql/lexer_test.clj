(ns minisql.lexer-test
  (:require [clojure.test :refer [deftest is testing]]
            [minisql.lexer :as lexer]))

(deftest keywords-and-identifiers
  (is (= [[:kw :select] [:id "emp"] [:kw :from] [:id "t_1"]]
         (lexer/tokenize "Select EMP FROM t_1")))
  (testing "aggregate names are ordinary identifiers"
    (is (= [[:id "count"] [:op "("] [:op "*"] [:op ")"]]
           (lexer/tokenize "count (*)")))))

(deftest literals
  (is (= [[:int "007"]] (lexer/tokenize "007")))
  (is (= [[:str "it's"]] (lexer/tokenize "'it''s'")))
  (is (= [[:str ""]] (lexer/tokenize "''")))
  (is (= [[:str "a\\nb;--"]] (lexer/tokenize "'a\\nb;--'")))
  (is (= [[:str "a\nb"]] (lexer/tokenize "'a\nb'"))))

(deftest operators-longest-match
  (is (= (map (fn [s] [:op s]) ["<=" ">=" "!=" "<>" "==" "<" ">" "=" "+" "-" "*" "/" "%" "." ","])
         (lexer/tokenize "<= >= != <> == < > = + - * / % . ,")))
  (is (= [[:op "<="] [:op "="]] (lexer/tokenize "<==")))
  (is (= [[:int "1"] [:op "."] [:int "5"]] (lexer/tokenize "1.5"))))

(deftest comments
  (is (= [[:int "1"] [:int "2"]] (lexer/tokenize "1 -- comment ; 'x\n2")))
  (is (= [[:int "1"]] (lexer/tokenize "1 -- trailing")))
  (is (= [] (lexer/tokenize "--5")) "-- always starts a comment"))

(deftest invalid-tokens
  (is (= [:invalid "\""] (first (lexer/tokenize "\"x\""))))
  (is (= [:invalid "é"] (first (lexer/tokenize "é"))))
  (is (= [:invalid "!"] (first (lexer/tokenize "!")))))

(deftest unterminated-string-stops-lexing
  (is (= [[:int "1"] [:unterminated nil]] (lexer/tokenize "1 'abc; 2"))))

(deftest statement-splitting
  (is (= [] (lexer/statements "")))
  (is (= [] (lexer/statements "  -- hi\n ;; ; ")))
  (is (= 3 (count (lexer/statements "a; b;; c"))) "final ; is optional")
  (is (= [[[:str ";"]]] (lexer/statements "';';")) "; in a string does not split")
  (is (= [[[:int "1"]] [[:unterminated nil]]]
         (lexer/statements "1; 'x; 2"))
      "nothing after an unterminated string is a separate statement"))
