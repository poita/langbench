(ns template.filters-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [template.core :as core]
            [template.filters :as f]))

(defn- kind [f] (try (f) nil (catch clojure.lang.ExceptionInfo e (core/error-kind e))))

(deftest string-filters
  (is (= "ABC1é" (f/apply-filter "upper" "abc1é" [])))
  (is (= "abc" (f/apply-filter "lower" "AbC" [])))
  (is (= "x y" (f/apply-filter "trim" " \t\n x y \r\f\u000B" [])))
  (is (= "&amp;&lt;&gt;&#34;&#39;&amp;amp;" (f/apply-filter "escape" "&<>\"'&amp;" [])))
  (is (= "bbb" (f/apply-filter "replace" "aaa" ["a" "b"])))
  (is (= "xx" (f/apply-filter "replace" "aaaa" ["aa" "x"])))
  (is (= "-2" (f/apply-filter "replace" 12 [1 "-"]))))

(deftest length-and-int
  (is (= 3 (f/apply-filter "length" "a😀b" [])))
  (is (= 2 (f/apply-filter "length" [1 2] [])))
  (is (= :type (kind #(f/apply-filter "length" 5 []))))
  (doseq [[in out] [[3 3] [3.9 3] [-3.9 -3] [true 1] ["  42 " 42] ["+7" 7] ["-3.9" -3] ["1e3" 1000]
                    [".5" 0] ["abc" 0] [nil 0] [[1] 0] ["" 0] ["5." 5]]]
    (is (= out (f/apply-filter "int" in [])) (pr-str in))))

(deftest sequence-filters
  (is (= "a, b" (f/apply-filter "join" ["a" "b"] [", "])))
  (is (= "1True" (f/apply-filter "join" [1 true] [])))
  (is (= "a-b" (f/apply-filter "join" "ab" ["-"])))
  (is (= 1 (f/apply-filter "first" [1 2] [])))
  (is (= "b" (f/apply-filter "last" "ab" [])))
  (is (= :template.values/undefined (f/apply-filter "first" [] [])))
  (is (= "cba" (f/apply-filter "reverse" "abc" [])))
  (is (= [3 2 1] (f/apply-filter "reverse" [1 2 3] []))))

(deftest sort-filter
  (is (= [1 2.5 3] (f/apply-filter "sort" [3 1 2.5] [])))
  (is (= ["a" "B" "c"] (f/apply-filter "sort" ["c" "B" "a"] [])))
  (is (= ["B" "b"] (f/apply-filter "sort" ["B" "b"] [])) "equal keys are stable")
  (is (= :type (kind #(f/apply-filter "sort" [1 "a"] [])))))

(deftest default-and-errors
  (is (= "" (f/apply-filter "default" :template.values/undefined [])))
  (is (= "d" (f/apply-filter "default" :template.values/undefined ["d"])))
  (is (= 0 (f/apply-filter "default" 0 ["d"])))
  (is (= :type (kind #(f/apply-filter "default" 1 [1 2]))))
  (is (= :undefined (kind #(f/apply-filter "upper" :template.values/undefined [1]))))
  (is (= :type (kind #(f/apply-filter "upper" "x" [1])))))

(defspec sort-matches-clojure-sort 200
  (prop/for-all [xs (gen/vector gen/small-integer)]
    (= (sort xs) (f/apply-filter "sort" (vec xs) []))))

(defspec reverse-twice-is-identity 200
  (prop/for-all [xs (gen/vector gen/small-integer)]
    (= xs (f/apply-filter "reverse" (f/apply-filter "reverse" xs []) []))))
