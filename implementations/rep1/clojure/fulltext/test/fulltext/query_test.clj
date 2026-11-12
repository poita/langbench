(ns fulltext.query-test
  (:require [clojure.test :refer [deftest is testing]]
            [fulltext.query :as q]))

(defn- atom* [& terms] [:atom (vec terms)])

(deftest lexing
  (is (= [[:phrase "cat"] :and [:phrase "dog"]] (q/lex "cat AND dog")))
  (is (= [:lparen [:phrase "a b"] :rparen] (q/lex "(\"a b\")")))
  (is (= [[:phrase "and"] [:phrase "Or"]] (q/lex "and Or")) "operators are upper case")
  (is (= [[:phrase "cat"]] (q/lex "\"cat")) "unterminated phrase")
  (is (= [[:phrase ""]] (q/lex "\"\"")))
  (is (= [[:phrase "a"] [:phrase "b"]] (q/lex "a\"b\"") ) "a quote ends a word"))

(deftest atoms-and-juxtaposition
  (is (= (atom* "cat") (q/parse "cat")))
  (is (= [:and [(atom* "cat") (atom* "dog")]] (q/parse "cat dog")))
  (is (= (atom* "well" "known") (q/parse "well-known")))
  (is (= (atom* "to" "be") (q/parse "\"to be\"")))
  (is (= (atom* "run") (q/parse "running"))))

(deftest precedence
  (is (= [:or [(atom* "a1") [:and [(atom* "b1") (atom* "c1")]]]]
         (q/parse "a1 OR b1 AND c1")))
  (is (= [:and [(atom* "a1") [:not (atom* "b1")]]] (q/parse "a1 NOT b1")))
  (is (= [:not [:not (atom* "a1")]] (q/parse "NOT NOT a1")))
  (is (= [:and [[:or [(atom* "a1") (atom* "b1")]] (atom* "c1")]]
         (q/parse "(a1 OR b1) c1"))))

(deftest empty-tree
  (doseq [s ["" "()" "the" "NOT" "AND" "OR" "\"\"" "NOT the" "(())" ")"]]
    (is (nil? (q/parse s)) s)))

(deftest recovery
  (testing "all of these parse to just `cat`"
    (doseq [s ["cat AND" "OR cat" "cat ()" "cat NOT ()" "cat NOT (" "(cat"
               "\"cat" "cat ) dog" "cat ) ) dog" "cat the" "cat AND AND"]]
      (is (= (atom* "cat") (q/parse s)) s)))
  (testing "adjacent operators are absorbed"
    (is (= [:or [(atom* "cat") (atom* "dog")]] (q/parse "cat OR AND dog")))
    (is (= [:or [(atom* "cat") (atom* "dog")]] (q/parse "cat AND OR dog")))
    (is (= [:and [(atom* "cat") (atom* "dog")]] (q/parse "cat AND AND dog"))))
  (testing "an unterminated group still yields its atom"
    (is (= [:and [(atom* "dog") [:not (atom* "cat")]]] (q/parse "dog NOT ( cat")))))

(deftest positive-atoms
  (is (= [["cat"] ["dog"]] (q/positive-atoms (q/parse "cat dog cat"))))
  (is (= [] (q/positive-atoms (q/parse "NOT cat"))))
  (is (= [["cat"]] (q/positive-atoms (q/parse "cat NOT dog"))))
  (is (= [["dog"]] (q/positive-atoms (q/parse "NOT (cat NOT dog)")))
      "double negation makes an atom positive again")
  (is (= [] (q/positive-atoms nil)))
  (is (= [["cat"] ["dog"]] (q/atoms (q/parse "cat NOT dog")))))
