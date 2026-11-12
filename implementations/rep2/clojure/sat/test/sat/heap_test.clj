(ns sat.heap-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [sat.heap :as heap]))

(deftest basic-operations
  (let [act (double-array [1.0 5.0 3.0 4.0])
        h (heap/make-heap 4 act)]
    (is (heap/empty? h))
    (doseq [v (range 4)] (heap/insert! h v))
    (heap/insert! h 2)                  ; duplicate insert is a no-op
    (is (= 4 (heap/size h)))
    (is (heap/in-heap? h 3))
    (testing "increasing a key moves it to the top"
      (aset act 0 10.0)
      (heap/increased! h 0)
      (is (= 0 (heap/remove-max! h))))
    (is (= [1 3 2] (repeatedly 3 #(heap/remove-max! h))))
    (is (= -1 (heap/remove-max! h)))
    (is (not (heap/in-heap? h 1)))))

(defspec removal-order-is-descending-activity 100
  (prop/for-all [acts (gen/vector (gen/double* {:NaN? false :infinite? false}) 1 40)]
    (let [n (count acts)
          h (heap/make-heap n (double-array acts))]
      (dotimes [v n] (heap/insert! h v))
      (let [order (repeatedly n #(heap/remove-max! h))
            vs (map #(nth acts %) order)]
        (and (= (set order) (set (range n)))
             (= vs (sort > vs)))))))
