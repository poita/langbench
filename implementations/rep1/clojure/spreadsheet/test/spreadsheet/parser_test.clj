(ns spreadsheet.parser-test
  (:require [clojure.test :refer [deftest is testing]]
            [spreadsheet.cell :as cell]
            [spreadsheet.parser :as p]))

(defn- id [n] (cell/parse-ref n))

(deftest literals-test
  (is (= [:num 5.0] (:ast (p/parse-content "5"))))
  (is (= [:num 0.0] (:ast (p/parse-content "-0"))))
  (is (= [:num 4.5] (:ast (p/parse-content "4.50"))))
  (is (= [:str "hi there"] (:ast (p/parse-content "\"hi there\""))))
  (is (= [:str ""] (:ast (p/parse-content "\"\""))))
  (is (= #{} (:deps (p/parse-content "5")))))

(deftest precedence-test
  (is (= [:arith :+ [:num 1.0] [:arith :* [:num 2.0] [:num 3.0]]]
         (p/parse-formula "1+2*3")))
  (is (= [:arith :- [:arith :- [:num 1.0] [:num 2.0]] [:num 3.0]]
         (p/parse-formula "1-2-3")))
  (is (= [:cmp :lt [:num 1.0] [:arith :+ [:num 2.0] [:num 3.0]]]
         (p/parse-formula "1<2+3")))
  (is (= [:cat [:arith :+ [:num 1.0] [:num 2.0]] [:num 3.0]]
         (p/parse-formula "1+2&3")))
  (is (= [:neg [:neg [:num 5.0]]] (p/parse-formula "--5")))
  (is (= [:arith :* [:num 2.0] [:neg [:num 3.0]]] (p/parse-formula "2*-3")))
  (is (= [:arith :* [:arith :+ [:num 1.0] [:num 2.0]] [:num 3.0]]
         (p/parse-formula "(1+2)*3"))))

(deftest whitespace-test
  (is (= (p/parse-formula "1+SUM(A1:B2)") (p/parse-formula "  1 +  SUM( A1:B2 )"))))

(deftest operators-test
  (doseq [[text op] [["=" :eq] ["<>" :ne] ["<" :lt] [">" :gt] ["<=" :le] [">=" :ge]]]
    (is (= [:cmp op [:num 1.0] [:num 2.0]] (p/parse-formula (str "1" text "2"))))))

(deftest functions-test
  (is (= [:if [:ref (id "A1")] [:str "y"] [:num 2.0]] (p/parse-formula "IF(A1,\"y\",2)")))
  (is (= [:agg :sum [[:range 1 1 2 2] [:num 3.0]]] (p/parse-formula "SUM(B2:A1,3)")))
  (is (= [:agg :count [[:ref (id "A1")]]] (p/parse-formula "COUNT(A1)"))))

(deftest dependencies-test
  (testing "ranges are expanded, both IF branches count"
    (is (= #{(id "A1") (id "B1") (id "A2") (id "B2") (id "C1") (id "D1")}
           (:deps (p/parse-content "=SUM(A1:B2)+IF(C1,D1,1)")))))
  (testing "invalid references yield #REF! and no dependencies"
    (doseq [f ["=AAA1" "=A0+B1" "=A10000" "=A01" "=IF(1,2,AAA1)" "=SUM(A1:A0)"]]
      (is (= {:ast [:err :error/ref] :deps #{}} (p/parse-content f)) f))))

(deftest deep-nesting-test
  (let [f (str (apply str (repeat 300 "(")) "1" (apply str (repeat 300 ")")))]
    (is (= [:num 1.0] (p/parse-formula f)))))
