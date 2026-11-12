(ns sat.luby-test
  (:require [clojure.test :refer [deftest is]]
            [sat.luby :refer [luby]]))

(deftest luby-sequence
  (is (= [1 1 2 1 1 2 4 1 1 2 1 1 2 4 8]
         (map #(long (luby 2.0 %)) (range 15)))))

(deftest luby-other-base
  (is (= [1.0 1.0 3.0 1.0 1.0 3.0 9.0] (mapv #(luby 3.0 %) (range 7)))))
