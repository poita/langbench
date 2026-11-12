(ns textbuffer.position-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [textbuffer.position :as p]))

(deftest pack-unpack
  (is (= [3 7] (p/->vec (p/pos 3 7))))
  (is (= 0 p/origin))
  (is (= 12000000 (p/col (p/pos 0 12000000)))))

(defspec ordering-is-lexicographic 200
  (prop/for-all [l1 (gen/choose 0 100000) c1 (gen/choose 0 3000000)
                 l2 (gen/choose 0 100000) c2 (gen/choose 0 3000000)]
    (= (compare [l1 c1] [l2 c2])
       (compare (p/pos l1 c1) (p/pos l2 c2)))))

(deftest advance-over-text
  (testing "no newline"
    (is (= [2 7] (p/->vec (p/advance (p/pos 2 3) "abcd")))))
  (testing "newlines"
    (is (= [3 2] (p/->vec (p/advance (p/pos 1 5) "a\nbc\nde"))))
    (is (= [2 0] (p/->vec (p/advance (p/pos 1 5) "\n"))))
    (is (= [1 5] (p/->vec (p/advance (p/pos 1 5) ""))))))

(deftest counting-newlines
  (is (= 0 (p/newline-count "")))
  (is (= 3 (p/newline-count "\na\n\n"))))

(deftest min-max
  (is (= (p/pos 1 2) (p/min (p/pos 1 2) (p/pos 1 3))))
  (is (= (p/pos 2 0) (p/max (p/pos 1 9) (p/pos 2 0)))))
