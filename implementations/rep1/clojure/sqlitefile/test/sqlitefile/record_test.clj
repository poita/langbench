(ns sqlitefile.record-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [sqlitefile.record :as record]))

(defn- norm [v] (if (bytes? v) (vec v) v))

(def gen-value
  (gen/one-of [(gen/return nil)
               gen/large-integer
               (gen/fmap double (gen/double* {:infinite? false :NaN? false}))
               gen/string
               (gen/fmap byte-array (gen/vector gen/byte 0 300))]))

(defspec encode-decode-roundtrip 300
  (prop/for-all [vs (gen/vector gen-value 0 12)]
    (= (mapv norm vs)
       (mapv norm (record/decode (record/encode vs))))))

(deftest hand-built-record
  ;; header size 5; types: NULL, int8, text(2), const 1
  (let [rec (byte-array (map unchecked-byte [5 0 1 17 9, 0x2a, 0x68 0x69]))]
    (is (= [nil 42 "hi" 1] (record/decode rec)))))

(deftest rejects-truncated-record
  (is (thrown? clojure.lang.ExceptionInfo
               (record/decode (byte-array (map unchecked-byte [2 17 0x68]))))))
