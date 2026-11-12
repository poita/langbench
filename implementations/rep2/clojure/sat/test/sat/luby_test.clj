(ns sat.luby-test
  (:require [clojure.test :refer [deftest is]]
            [sat.luby :refer [luby]]))

(deftest sequence-prefix
  (is (= [1 1 2 1 1 2 4 1 1 2 1 1 2 4 8]
         (map #(luby 2 %) (range 15)))))

(deftest scaling
  (is (= [100 100 200 100 100 200 400] (map #(* 100 (luby 2 %)) (range 7))))
  (is (= [1 1 3 1 1 3 9] (map #(luby 3 %) (range 7)))))
