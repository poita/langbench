(ns toml.number-test
  (:require [clojure.test :refer [deftest is testing are]]
            [toml.data :as d]
            [toml.number :as n]))

(deftest format-float-test
  (are [x text] (= text (n/format-float x))
    1.0 "1.0000000000000000e+00"
    3.1415 "3.1415000000000002e+00"
    -0.0 "-0.0000000000000000e+00"
    0.0 "0.0000000000000000e+00"
    1e308 "1.0000000000000000e+308"
    6.626e-34 "6.6259999999999998e-34"
    4.9E-324 "4.9406564584124654e-324"
    Double/NaN "nan"
    Double/POSITIVE_INFINITY "inf"
    Double/NEGATIVE_INFINITY "-inf"))

(deftest integers
  (are [t v] (= (d/scalar :integer v) (n/parse-number t))
    "0" "0", "+17" "17", "-17" "-17", "1_000" "1000"
    "0xDEAD_beef" "3735928559", "0o17" "15", "0b101" "5"
    "9223372036854775807" "9223372036854775807"
    "-9223372036854775808" "-9223372036854775808"))

(deftest invalid-integers
  (doseq [t ["01" "+01" "1__0" "_1" "1_" "0x" "0X1" "-0x1" "0o8" "0b2"
             "9223372036854775808" "0xFFFFFFFFFFFFFFFF" "1x" ""]]
    (is (nil? (n/parse-number t)) t)))

(deftest floats
  (are [t v] (= (d/scalar :float v) (n/parse-number t))
    "1.5" "1.5000000000000000e+00"
    "1e2" "1.0000000000000000e+02"
    "0e00" "0.0000000000000000e+00"
    "-2E-2" "-2.0000000000000000e-02"
    "inf" "inf", "+inf" "inf", "-inf" "-inf"
    "nan" "nan", "-nan" "nan"
    "1e400" "inf"
    "1e-400" "0.0000000000000000e+00"))

(deftest invalid-floats
  (doseq [t [".5" "5." "1.e2" "1e" "01.5" "1.5.2" "Inf" "NaN" "1._5" "1e_5" "+-1"]]
    (is (nil? (n/parse-number t)) t)))
