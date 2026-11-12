(ns sat.heap-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [sat.heap :as heap]))

(deftest basic-ordering
  (let [act (double-array [1.0 5.0 3.0 4.0])
        h (heap/make-heap 4 act)]
    (dotimes [v 4] (heap/insert! h v))
    (is (= [1 3 2 0] (repeatedly 4 #(heap/remove-max! h))))
    (is (heap/empty-heap? h))))

(deftest increase-reorders
  (let [act (double-array [1.0 2.0 3.0])
        h (heap/make-heap 3 act)]
    (dotimes [v 3] (heap/insert! h v))
    (aset act 0 10.0)
    (heap/increased! h 0)
    (is (= 0 (heap/remove-max! h)))
    (is (not (heap/in-heap? h 0)))
    (heap/insert! h 0)
    (heap/insert! h 0)                  ; duplicate insert is a no-op
    (is (= 3 (heap/size h)))))

(defspec pops-in-descending-activity-order 100
  (prop/for-all [acts (gen/vector (gen/double* {:min 0 :max 1000 :NaN? false :infinite? false}) 1 60)]
    (let [n (count acts)
          arr (double-array acts)
          h (heap/make-heap n arr)]
      (dotimes [v n] (heap/insert! h v))
      (let [popped (vec (repeatedly n #(aget arr (heap/remove-max! h))))]
        (= popped (vec (sort > acts)))))))
