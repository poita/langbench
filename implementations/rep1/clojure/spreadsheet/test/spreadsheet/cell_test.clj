(ns spreadsheet.cell-test
  (:require [clojure.test :refer [deftest is testing]]
            [spreadsheet.cell :as cell]))

(deftest parse-ref-test
  (testing "valid names round-trip"
    (doseq [n ["A1" "Z9" "AA10" "ZZ9999" "AB123" "B2"]]
      (is (= n (cell/id->name (cell/parse-ref n))))))
  (testing "invalid names"
    (doseq [n ["AAA1" "A0" "A10000" "A01" "A" "1" "a1" "A1B"]]
      (is (nil? (cell/parse-ref n)) n))))

(deftest ordering-test
  (testing "ids ascend in row-major order"
    (let [ids (map cell/parse-ref ["A1" "B1" "Z1" "AA1" "ZZ1" "A2"])]
      (is (= ids (sort ids))))))

(deftest columns-test
  (is (= "A" (cell/col-name 1)))
  (is (= "Z" (cell/col-name 26)))
  (is (= "AA" (cell/col-name 27)))
  (is (= "AZ" (cell/col-name 52)))
  (is (= "ZZ" (cell/col-name 702))))
