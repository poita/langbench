(ns spreadsheet.format-test
  (:require [clojure.test :refer [deftest is are]]
            [spreadsheet.format :as fmt]))

(deftest number-display-test
  (are [v s] (= s (fmt/number->string v))
    0.0 "0"
    -0.0 "0"
    42.0 "42"
    -7.0 "-7"
    123456789012345.0 "123456789012345"
    1e14 "100000000000000"
    1e15 "1e+15"
    1e20 "1e+20"
    -1.5e15 "-1.5e+15"
    1.23456789e15 "1.23456789e+15"
    1e-5 "1e-05"
    2.5e-10 "2.5e-10"
    0.5 "0.5"
    1234567.891 "1234567.891"
    (/ 1.0 3) "0.3333333333"
    (/ 2.0 3) "0.6666666667"
    0.0001234 "0.0001234"
    -2.5 "-2.5"
    1234567890.4 "1234567890"
    1234567890.5 "1234567890"
    1234567891.5 "1234567892"
    2500000000.75 "2500000001"
    1200000000.4 "1200000000"
    9999999999.7 "1e+10"
    0.1 "0.1"
    1e-300 "1e-300"
    1e300 "1e+300"))

(deftest display-test
  (is (= "" (fmt/display nil)))
  (is (= "abc" (fmt/display "abc")))
  (is (= "#DIV/0!" (fmt/display :error/div0)))
  (is (= "#REF!" (fmt/display :error/ref)))
  (is (= "#CYCLE!" (fmt/display :error/cycle)))
  (is (= "#VALUE!" (fmt/display :error/value)))
  (is (= "5" (fmt/display 5.0))))
