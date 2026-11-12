(ns typeset.util-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [typeset.util :as u]))

(deftest floor-division
  (is (= -649 (u/fdiv (* -3890 850) 5100)) "floor, not truncation")
  (is (= 3 (u/fdiv 7 2)))
  (is (= -4 (u/fdiv -7 2)))
  (is (= 0 (u/fdiv 0 5))))

(deftest scaling
  (is (= 15630 (u/scale 1563 10000)))
  (is (= 10540 (u/scale 1054 10000)))
  (is (= 11594 (u/scale 1054 11000)))
  (is (= -600 (u/scale -60 10000))))

(deftest roman-numerals
  (is (= "i" (u/roman 1)))
  (is (= "iv" (u/roman 4)))
  (is (= "ix" (u/roman 9)))
  (is (= "xiv" (u/roman 14)))
  (is (= "xl" (u/roman 40)))
  (is (= "mmxxvi" (u/roman 2026)))
  (is (= "mmmm" (u/roman 4000)))
  (is (= "mmmmmi" (u/roman 5001))))

(deftest bijective-letters
  (is (= "a" (u/letters 1)))
  (is (= "z" (u/letters 26)))
  (is (= "aa" (u/letters 27)))
  (is (= "ab" (u/letters 28)))
  (is (= "az" (u/letters 52)))
  (is (= "ba" (u/letters 53))))

(deftest badness-ratio
  (testing "values from the specification's badness table"
    (is (= 522 (u/cube-ratio 11020 6350)))
    (is (= 44 (u/cube-ratio 3890 5100)))
    (is (= 76 (u/cube-ratio 3110 3400)))
    (is (= 10000 (u/cube-ratio 30950 5080)))))

(defspec cube-ratio-is-exact 200
  (prop/for-all [d (gen/choose 0 3000000) y (gen/choose 1 3000000)]
    (let [exact (.divide (.multiply (biginteger 100) (.pow (biginteger d) 3))
                         (.pow (biginteger y) 3))]
      (= (min 10000 (long exact)) (u/cube-ratio d y)))))

(defspec floor-division-law 200
  (prop/for-all [a (gen/choose -1000000 1000000) b (gen/choose 1 5000)]
    (let [q (u/fdiv a b) r (- a (* q b))]
      (and (<= 0 r) (< r b)))))

(defspec roman-length-and-alphabet 100
  (prop/for-all [n (gen/choose 1 3999)]
    (boolean (re-matches #"[mdclxvi]+" (u/roman n)))))

(defspec letters-are-bijective 100
  (prop/for-all [n (gen/choose 1 20000)]
    (let [s (u/letters n)]
      (= n (reduce (fn [acc c] (+ (* acc 26) (- (int c) 96))) 0 s)))))
