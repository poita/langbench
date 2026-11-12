(ns typeinfer.lexer-test
  (:require [clojure.test :refer [deftest is testing]]
            [typeinfer.lexer :as lexer]))

(defn- kinds+texts [src] (mapv (comp vec (partial take 2)) (lexer/tokenize src)))

(deftest tokenize-test
  (testing "keywords vs identifiers"
    (is (= [[:tok "let"] [:ident "letx"] [:tok "in"] [:ident "inx"] [:ident "funny"]]
           (kinds+texts "let letx in inx funny"))))
  (testing "identifier characters"
    (is (= [[:ident "acc_2"] [:ident "xY9"]] (kinds+texts "acc_2 xY9"))))
  (testing "longest match for symbols"
    (is (= [[:tok "->"] [:tok "::"] [:tok "<="] [:tok ">="] [:tok "&&"] [:tok "||"]
            [:tok ";;"] [:tok ";"] [:tok "<"] [:tok ">"] [:tok "-"]]
           (kinds+texts "-> :: <= >= && || ;; ; < > -"))))
  (testing "no whitespace needed between symbols and operands"
    (is (= [[:tok "("] [:int "1"] [:tok ","] [:ident "x"] [:tok ")"] [:tok ";;"]]
           (kinds+texts "(1,x);;"))))
  (testing "big integers and any whitespace"
    (is (= [[:int "123456789012345678901234567890"] [:int "0"]]
           (kinds+texts "\t123456789012345678901234567890\r\n0 "))))
  (testing "empty input"
    (is (= [] (lexer/tokenize "  \n"))))
  (testing "bad character"
    (is (thrown? clojure.lang.ExceptionInfo (lexer/tokenize "let x = #;;")))))
