(ns jq.parser-test
  (:require [clojure.test :refer [deftest is testing]]
            [jq.lexer :as lexer]
            [jq.parser :as parser]))

(deftest tokens
  (is (= [[:field "a"] [:op "|"] [:num 1.5] [:op "<="] [:str "x\ny"] [:var "v"] [:id "as"]]
         (lexer/tokenize ".a | 1.5 <= \"x\\ny\" $v as")))
  (is (= [[:op "."] [:op "["] [:op "]"] [:op "?"]] (lexer/tokenize ".[]?")))
  (is (thrown? clojure.lang.ExceptionInfo (lexer/tokenize "@"))))

(deftest precedence
  (testing "pipe is loosest, comma binds tighter"
    (is (= :pipe (:op (parser/parse "1, 2 | 3"))))
    (is (= :comma (:op (:l (parser/parse "1, 2 | 3")))))
    (is (= :comma (:op (:r (parser/parse "1 | 2, 3"))))))
  (testing "arithmetic"
    (let [ast (parser/parse "1 + 2 * 3")]
      (is (= :+ (:f ast)))
      (is (= :* (:f (:r ast)))))
    (is (= :- (:f (parser/parse "1 -1"))))
    (is (= :neg (:op (parser/parse "-1")))))
  (testing "and binds tighter than or"
    (is (= :or (:op (parser/parse "a or b and c"))))))

(deftest optional-meanings
  (is (true? (:opt (parser/parse ".a?"))))
  (is (= :try (:op (parser/parse "(.a)?"))))
  (is (= :try (:op (parser/parse ".a??"))))
  (is (true? (:opt (parser/parse ".[]?"))))
  (is (= :index (:op (:term (parser/parse ".a.b?"))))))

(deftest binding-and-reduce
  (let [ast (parser/parse ".[] as $x | $x + 1")]
    (is (= :bind (:op ast)))
    (is (= "x" (:name ast))))
  (let [ast (parser/parse "reduce .[] as $i (0; . + $i)")]
    (is (= :reduce (:op ast)))))

(deftest object-construction
  (let [ast (parser/parse "{a, \"b\": 1, (.k): .v | .w, $x}")]
    (is (= 4 (count (:entries ast))))
    (is (= :pipe (:op (second (nth (:entries ast) 2)))))))

(deftest slices
  (is (= :slice (:op (parser/parse ".[1:2]"))))
  (is (nil? (:from (parser/parse ".[:2]"))))
  (is (nil? (:to (parser/parse ".[1:]")))))

(deftest errors
  (doseq [bad ["" ".[" "1 +" "if . then 1" "{a:}" "frob(" ". as x | 1"]]
    (testing bad
      (is (thrown? clojure.lang.ExceptionInfo (parser/parse bad))))))
