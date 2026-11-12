(ns qrcode.segment-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [qrcode.bits :as bits]
            [qrcode.segment :as seg])
  (:import (java.nio.charset StandardCharsets)))

(defn- utf8 [^String s] (.getBytes s StandardCharsets/UTF_8))

(deftest mode-selection
  (is (= :numeric (seg/select-mode (utf8 "0123456789"))))
  (is (= :alphanumeric (seg/select-mode (utf8 "HELLO WORLD"))))
  (is (= :alphanumeric (seg/select-mode (utf8 "$%*+-./:"))))
  (is (= :alphanumeric (seg/select-mode (utf8 "123A"))))
  (is (= :byte (seg/select-mode (utf8 "hello"))))
  (is (= :byte (seg/select-mode (utf8 "ABC#"))))
  (is (= :byte (seg/select-mode (utf8 "é")))))

(deftest count-indicator-widths
  (is (= [10 12 14] (map #(seg/count-indicator-bits :numeric %) [9 10 27])))
  (is (= [9 11 13] (map #(seg/count-indicator-bits :alphanumeric %) [9 26 27])))
  (is (= [8 16 16] (map #(seg/count-indicator-bits :byte %) [9 10 40]))))

(deftest data-bit-lengths
  (is (= [0 4 7 10 14] (map #(seg/data-bit-length :numeric %) (range 5))))
  (is (= [0 6 11 17] (map #(seg/data-bit-length :alphanumeric %) (range 4))))
  (is (= 24 (seg/data-bit-length :byte 3))))

(deftest version-selection
  ;; Version 1 holds 41 digits / 25 alphanumerics / 17 bytes at L.
  (is (= 1 (seg/choose-version :numeric 41 :l)))
  (is (= 2 (seg/choose-version :numeric 42 :l)))
  (is (= 1 (seg/choose-version :alphanumeric 25 :l)))
  (is (= 2 (seg/choose-version :alphanumeric 26 :l)))
  (is (= 1 (seg/choose-version :byte 17 :l)))
  (is (= 2 (seg/choose-version :byte 18 :l)))
  ;; Maximum capacities at version 40.
  (is (= 40 (seg/choose-version :numeric 7089 :l)))
  (is (nil? (seg/choose-version :numeric 7090 :l)))
  (is (= 40 (seg/choose-version :byte 1273 :h)))
  (is (nil? (seg/choose-version :byte 1274 :h))))

(defn- bit-string [buf n]
  (let [cw (bits/codewords buf)]
    (apply str (for [i (range n)]
                 (if (bit-test (aget cw (quot i 8)) (- 7 (rem i 8))) \1 \0)))))

(deftest numeric-segment-bits
  (let [buf (bits/buffer 19)]
    (seg/write-segment! buf :numeric (utf8 "01234567") 1)
    ;; 0001 | 0000001000 | 0000001100 0101011001 1000011
    (is (= "0001000000100000000011000101011001" (bit-string buf 34)))
    (is (= 41 (bits/length buf)))))

(deftest alphanumeric-segment-bits
  (let [buf (bits/buffer 16)]
    (seg/write-segment! buf :alphanumeric (utf8 "AC-") 1)
    ;; 0010 | 000000011 | (45*10+12=462) 00111001110 | 41 -> 101001
    (is (= "001000000001100111001110101001" (bit-string buf 30)))))

(defspec segment-length-matches-closed-form 100
  (prop/for-all [s (gen/such-that seq (gen/fmap #(apply str %)
                                                (gen/vector (gen/elements "0123456789") 1 200)))
                 v (gen/choose 1 40)]
    (let [data (utf8 s)
          buf (bits/buffer 4000)]
      (seg/write-segment! buf :numeric data v)
      (= (bits/length buf) (seg/stream-bit-length :numeric (alength data) v)))))
