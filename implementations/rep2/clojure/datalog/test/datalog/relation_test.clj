(ns datalog.relation-test
  (:require [clojure.test :refer [deftest is]]
            [datalog.relation :as rel]))

(defn- longs-of [& xs] (long-array xs))

(deftest add-and-member-test
  (let [r (rel/make-relation)]
    (is (true? (rel/add! r [1 2])))
    (is (nil? (rel/add! r [1 2])) "duplicates are rejected")
    (is (rel/member? r [1 2]))
    (is (not (rel/member? r [2 1])))
    (is (= 1 (rel/size r)))))

(deftest visibility-test
  (let [r (rel/make-relation)
        idx (rel/index r (longs-of 0))]
    (rel/add! r [1 10])
    (is (= 0 (rel/visible-size r)))
    (is (nil? (rel/lookup r idx 1)) "added rows are invisible until freeze!")
    (rel/freeze! r)
    (is (= [[1 10]] (vec (rel/lookup r idx 1))))
    (rel/add! r [1 11])
    (is (= [[1 10]] (vec (rel/lookup r idx 1))))
    (rel/freeze! r)
    (is (= [[1 10] [1 11]] (vec (rel/lookup r idx 1))))))

(deftest multi-position-index-test
  (let [r (rel/make-relation)
        idx (rel/index r (longs-of 0 2))]
    (doseq [t [[1 5 2] [1 6 2] [1 6 3] [2 5 2]]] (rel/add! r t))
    (rel/freeze! r)
    (is (= [[1 5 2] [1 6 2]] (vec (rel/lookup r idx [1 2]))))
    (is (nil? (rel/lookup r idx [9 9])))
    (is (identical? idx (rel/index r (longs-of 0 2))) "indexes are reused")))
