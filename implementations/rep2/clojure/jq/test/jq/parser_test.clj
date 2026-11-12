(ns jq.parser-test
  (:require [clojure.test :refer [deftest is]]
            [jq.parser :as parser]))

(deftest precedence
  (is (= [:pipe [:identity] [:comma [:lit 1.0] [:lit 2.0]]] (parser/parse ". | 1, 2")))
  (is (= [:pipe [:comma [:lit 1.0] [:lit 2.0]] [:call "f" []]] (parser/parse "(1, 2) | f")))
  (is (= [:binop :+ [:lit 1.0] [:binop :* [:lit 2.0] [:lit 3.0]]] (parser/parse "1 + 2 * 3")))
  (is (= [:binop :- [:binop :- [:lit 1.0] [:lit 2.0]] [:lit 3.0]] (parser/parse "1 -2 - 3")))
  (is (= [:or [:var "a"] [:and [:var "b"] [:var "c"]]]
         (parser/parse "$a or $b and $c"))))

(deftest suffixes-and-optional
  (is (= [:index [:index [:identity] [:lit "a"] false] [:lit "b"] true] (parser/parse ".a.b?")))
  (is (= [:try [:index [:identity] [:lit "a"] true]] (parser/parse ".a??")))
  (is (= [:try [:call "f" []]] (parser/parse "f?")))
  (is (= [:iterate [:identity] true] (parser/parse ".[]?")))
  (is (= [:slice [:identity] [:lit 1.0] nil false] (parser/parse ".[1:]")))
  (is (= [:slice [:identity] nil [:lit 2.0] false] (parser/parse ".[:2]")))
  (is (= [:index [:identity] [:lit "a b"] false] (parser/parse ".\"a b\""))))

(deftest binding-extends-right
  (is (= [:bind [:iterate [:identity] false] "x" [:pipe [:var "x"] [:call "f" []]]]
         (parser/parse ".[] as $x | $x | f"))))

(deftest objects
  (is (= [:object [[[:lit "a"] [:index [:identity] [:lit "a"] false]]
                   [[:lit "x"] [:var "x"]]
                   [[:lit "k"] [:pipe [:identity] [:call "f" []]]]]]
         (parser/parse "{a, $x, k: . | f}")))
  (is (= [:object []] (parser/parse "{}"))))

(deftest if-chains
  (is (= [:if [:var "a"] [:lit 1.0] [:if [:var "b"] [:lit 2.0] [:lit 3.0]]]
         (parser/parse "if $a then 1 elif $b then 2 else 3 end")))
  (is (= [:if [:var "a"] [:lit 1.0] [:identity]] (parser/parse "if $a then 1 end"))))

(deftest syntax-errors
  (doseq [bad ["(" "1 +" "if . then 1" "{a:}" ".[" "reduce . as $x (0)"]]
    (is (thrown? clojure.lang.ExceptionInfo (parser/parse bad)) bad)))
