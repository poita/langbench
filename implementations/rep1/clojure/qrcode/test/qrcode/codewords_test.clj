(ns qrcode.codewords-test
  (:require [clojure.test :refer [deftest is]]
            [qrcode.codewords :as cw]
            [qrcode.tables :as tables])
  (:import (java.nio.charset StandardCharsets)))

(defn- utf8 [^String s] (.getBytes s StandardCharsets/UTF_8))

(deftest hello-world-data-and-ecc
  (let [data (cw/data-codewords :alphanumeric (utf8 "HELLO WORLD") 1 :m)]
    (is (= [32 91 11 120 209 114 220 77 67 64 236 17 236 17 236 17] (vec data)))
    (is (= (concat [32 91 11 120 209 114 220 77 67 64 236 17 236 17 236 17]
                   [196 35 39 119 235 215 231 226 93 23])
           (vec (cw/interleave-blocks data 1 :m))))))

(deftest terminator-is-truncated-at-capacity
  ;; 17 bytes at v1-L: 4 + 8 + 136 = 148 bits of 152, so only 4 bits remain
  ;; and the full terminator fits; 19 codewords, no pad bytes.
  (let [data (cw/data-codewords :byte (utf8 "12345678901234567") 1 :l)]
    (is (= 19 (alength data)))
    (is (= 0x00 (bit-and (aget data 18) 0x0F))))
  ;; 41 digits at v1-L: 4 + 10 + 137 = 151 bits; a single terminator bit fits.
  (let [data (cw/data-codewords :numeric (utf8 (apply str (repeat 41 "7"))) 1 :l)]
    (is (= 19 (alength data)))))

(deftest interleaving-multiple-blocks
  ;; Version 5-Q: 4 blocks (2 short with 15 data, 2 long with 16), 18 ECC each.
  (let [v 5, ecl :q
        n (tables/data-codewords ecl v)
        data (int-array (range n))
        out (cw/interleave-blocks data v ecl)]
    (is (= 62 n))
    (is (= (tables/total-codewords v) (alength out)))
    ;; First row of the data region takes codeword 0 of each block.
    (is (= [0 15 30 46] (vec (take 4 out))))
    ;; The last data position holds only the long blocks' final codewords.
    (is (= [45 61] (vec (take 2 (drop 60 out)))))))
