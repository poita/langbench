(ns sqlitefile.bytes-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [sqlitefile.bytes :as b]))

(defn- bs [& xs] (byte-array (map unchecked-byte xs)))

(deftest fixed-width-reads
  (is (= 0xab (b/u8 (bs 0xab) 0)))
  (is (= 0x1234 (b/u16 (bs 0 0x12 0x34) 1)))
  (is (= 0xdeadbeef (b/u32 (bs 0xde 0xad 0xbe 0xef) 0)))
  (is (= -2 (b/signed (bs 0xff 0xfe) 0 2)))
  (is (= 0x7fffffffffffffff (b/signed (bs 0x7f 0xff 0xff 0xff 0xff 0xff 0xff 0xff) 0 8)))
  (is (= -140737488355328 (b/signed (bs 0x80 0 0 0 0 0) 0 6))))

(deftest varint-examples
  (testing "one to nine bytes"
    (is (= 0 (b/varint (bs 0) 0)))
    (is (= 127 (b/varint (bs 0x7f) 0)))
    (is (= 128 (b/varint (bs 0x81 0x00) 0)))
    (is (= 2 (b/varint-size (bs 0x81 0x00) 0)))
    (is (= 9 (b/varint-size (bs 0x81 0x81 0x81 0x81 0x81 0x81 0x81 0x81 0x01) 0))))
  (testing "negative values use all nine bytes"
    (is (= -1 (b/varint (bs 0xff 0xff 0xff 0xff 0xff 0xff 0xff 0xff 0xff) 0)))
    (is (= Long/MIN_VALUE (b/varint (bs 0xc0 0x80 0x80 0x80 0x80 0x80 0x80 0x80 0x00) 0)))))

(defspec varint-roundtrip 500
  (prop/for-all [n gen/large-integer]
    (let [enc (b/encode-varint n)]
      (and (= n (b/varint enc 0))
           (= (alength enc) (b/varint-size enc 0))
           (<= 1 (alength enc) 9)
           (or (>= n 0) (= 9 (alength enc)))))))
