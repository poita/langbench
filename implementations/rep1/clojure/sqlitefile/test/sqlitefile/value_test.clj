(ns sqlitefile.value-test
  (:require [clojure.test :refer [deftest is testing are]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [sqlitefile.value :as v]))

(deftest real-formatting
  (are [d s] (= s (v/format-value d))
    1.0 "1.0"
    0.1 "0.1"
    -3.25 "-3.25"
    (/ 1.0 3) "0.333333333333333"
    1e300 "1.0e+300"
    2.5e-10 "2.5e-10"
    1.5e16 "1.5e+16"
    1e14 "100000000000000.0"
    1e15 "1.0e+15"
    0.0001 "0.0001"
    1e-5 "1.0e-05"
    0.0 "0.0"
    -0.0 "0.0"
    123456.789 "123456.789"))

(deftest other-formatting
  (is (= "NULL" (v/format-value nil)))
  (is (= "-9223372036854775808" (v/format-value Long/MIN_VALUE)))
  (is (= "héllo" (v/format-value "héllo")))
  (is (= "007F" (v/format-value (byte-array [0 0x7f]))))
  (is (= "" (v/format-value (byte-array 0)))))

(deftest ordering
  (let [cmp v/compare-values]
    (testing "storage classes"
      (is (neg? (cmp nil 0)))
      (is (neg? (cmp 1e300 "")))
      (is (neg? (cmp "zzz" (byte-array 0))))
      (is (zero? (cmp nil nil))))
    (testing "numbers"
      (is (zero? (cmp 1 1.0)))
      (is (neg? (cmp 1 1.5)))
      (is (neg? (cmp 9223372036854775806 Long/MAX_VALUE)) "neighbouring large integers differ")
      (is (neg? (cmp 9007199254740992 9007199254740993)) "beyond 2^53 stays exact"))
    (testing "text is ordered by UTF-8 bytes, not UTF-16 units"
      (is (neg? (cmp "～" "😀")) "U+FF5E < U+1F600 as code points")
      (is (neg? (cmp "ab" "abc"))))
    (testing "blobs are unsigned"
      (is (neg? (cmp (byte-array [0x7f]) (byte-array [(unchecked-byte 0x80)]))))
      (is (neg? (cmp (byte-array [1]) (byte-array [1 0])))))))

(defspec ordering-is-antisymmetric 200
  (prop/for-all [a (gen/one-of [(gen/return nil) gen/large-integer gen/string])
                 b (gen/one-of [(gen/return nil) gen/large-integer gen/string])]
    (= (v/compare-values a b) (- (v/compare-values b a)))))

(deftest affinity-rules
  (are [t a] (= a (v/affinity t))
    "INTEGER" :integer "NVARCHAR(160)" :text "NUMERIC(10,2)" :numeric
    "" :blob nil :blob "BLOB" :blob "DOUBLE PRECISION" :real
    "POINT" :integer "FLOATING POINT" :integer "STRING" :numeric
    "INTTEXT" :integer "CHARFLOA" :text "BLOBREAL" :blob "DECIMAL" :numeric))

(deftest literal-affinity
  (are [aff lit out] (= out (v/apply-affinity aff lit))
    :text 5 "5"
    :text 1.5 "1.5"
    :text 2.0 "2.0"
    :integer "5" 5
    :integer " 5 " 5
    :integer ".5" 0.5
    :integer "-.5" -0.5
    :integer "5." 5.0
    :integer "+5e0" 5.0
    :real "7" 7
    :numeric "9223372036854775807" 9223372036854775807
    :numeric "9223372036854775808" 9.223372036854775808E18
    :integer "0x10" "0x10"
    :integer "" ""
    :integer "-" "-"
    :integer "5 x" "5 x"
    :blob "5" "5"
    :integer nil nil))
