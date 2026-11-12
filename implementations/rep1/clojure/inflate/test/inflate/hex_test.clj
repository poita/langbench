(ns inflate.hex-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [inflate.hex :as hex]))

(deftest decode-test
  (is (= [0 1 127 -128 -1] (vec (hex/decode "00017f80ff"))))
  (is (= [] (vec (hex/decode ""))))
  (testing "whitespace around the digits is ignored"
    (is (= [-85] (vec (hex/decode " ab\n")))))
  (testing "bad input"
    (is (thrown? IllegalArgumentException (hex/decode "abc")))
    (is (thrown? IllegalArgumentException (hex/decode "zz")))))

(deftest encode-test
  (is (= "00017f80ff" (hex/encode (byte-array [0 1 127 -128 -1]))))
  (is (= "" (hex/encode (byte-array 0)))))

(defspec hex-round-trip 100
  (prop/for-all [bs (gen/vector gen/byte)]
    (= bs (vec (hex/decode (hex/encode (byte-array bs)))))))
