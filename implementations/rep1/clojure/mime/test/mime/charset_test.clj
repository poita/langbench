(ns mime.charset-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [mime.charset :as cs]))

(defn- bs [& xs] (byte-array (map #(unchecked-byte %) xs)))

(deftest utf8-maximal-subpart
  (is (= "�(�" (cs/decode-utf8 (bs 0xe2 0x28 0xa1))))
  (is (= "�" (cs/decode-utf8 (bs 0xf0 0x9f))))
  (is (= "��" (cs/decode-utf8 (bs 0xc0 0xaf))))
  (is (= "��A" (cs/decode-utf8 (bs 0xed 0xa0 0x41)))
      "0xED stops at the out-of-range second byte, which is then read again")
  (is (= "\u00e9" (cs/decode-utf8 (bs 0xc3 0xa9)))))

(deftest charset-tables
  (is (= "café" (cs/decode (bs 0x63 0x61 0x66 0xe9) " ISO-8859-1\t")))
  (is (= "’" (cs/decode (bs 0x92) "windows-1252")))
  (is (= "\u0092" (cs/decode (bs 0x92) "latin1")))
  (is (= "�" (cs/decode (bs 0xe9) "us-ascii")))
  (is (= "é" (cs/decode (bs 0xe9) "")) "empty name falls back to cp1252")
  (is (= "é" (cs/decode (bs 0xe9) "x-unknown"))))

(defspec utf8-round-trips-valid-text 200
  (prop/for-all [s gen/string]
    (= s (cs/decode-utf8 (cs/encode-utf8 s)))))

(defspec utf8-decoder-never-throws 200
  (prop/for-all [v (gen/vector gen/byte 0 40)]
    (string? (cs/decode-utf8 (byte-array v)))))
