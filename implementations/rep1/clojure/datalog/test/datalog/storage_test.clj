(ns datalog.storage-test
  (:require [clojure.test :refer [deftest is testing]]
            [datalog.storage :as st])
  (:import (datalog.storage IIndex IRelation)))

(defn- tup [& xs] (int-array xs))

(deftest add-dedups-test
  (let [^IRelation r (st/make-relation 2)]
    (is (true? (.add r (tup 1 2))))
    (is (false? (.add r (tup 1 2))))
    (is (true? (.add r (tup 2 1))))
    (is (= 2 (.size r)))
    (is (true? (.has r (tup 2 1))))
    (is (false? (.has r (tup 2 2))))))

(deftest visibility-and-delta-test
  (let [^IRelation r (st/make-relation 1)]
    (.add r (tup 5))
    (.add r (tup 6))
    (is (= 0 (.visible r)) "rows are invisible until committed")
    (.commit r)
    (is (= [0 2 2] [(.deltaLo r) (.deltaHi r) (.visible r)]))
    (.add r (tup 7))
    (.commit r)
    (is (= [2 3 3] [(.deltaLo r) (.deltaHi r) (.visible r)]))
    (.commit r)
    (is (= [3 3] [(.deltaLo r) (.deltaHi r)]) "an empty commit empties the delta")))

(deftest index-test
  (let [^IRelation r (st/make-relation 2)]
    (dotimes [i 1000] (.add r (tup (mod i 10) i)))
    (.commit r)
    (let [^IIndex ix (.indexOn r (int-array [0]))
          chain (fn [k] (take-while #(>= % 0)
                                    (iterate #(.chainNext ix %) (.lookup ix (.data r) (tup k)))))]
      (is (= 100 (count (chain 3))))
      (is (every? #(= 3 (first (st/row r %))) (chain 3)))
      (is (empty? (chain 42))))
    (testing "rows committed later reach existing indexes"
      (.add r (tup 3 5000))
      (.commit r)
      (let [^IIndex ix (.indexOn r (int-array [0]))]
        (is (= 101 (count (take-while #(>= % 0)
                                      (iterate #(.chainNext ix %)
                                               (.lookup ix (.data r) (tup 3)))))))))
    (testing "an index created on demand covers existing rows"
      (let [^IIndex ix (.indexOn r (int-array [1]))]
        (is (>= (.lookup ix (.data r) (tup 777)) 0))))))

(deftest growth-test
  (let [^IRelation r (st/make-relation 3)]
    (dotimes [i 100000] (.add r (tup i (* 2 i) 7)))
    (is (= 100000 (.size r)))
    (is (every? #(.has r (tup % (* 2 %) 7)) (range 0 100000 997)))))
