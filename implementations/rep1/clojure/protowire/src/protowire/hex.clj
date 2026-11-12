(ns protowire.hex
  "Lowercase hexadecimal conversion."
  (:require [protowire.error :as err]))

(set! *warn-on-reflection* true)
(set! *unchecked-math* true)

(defn- code
  "UTF-16 code unit at index `i` of `s` as a long."
  ^long [^String s ^long i]
  (long (int (.charAt s i))))

(def ^:private digits (char-array "0123456789abcdef"))

(defn append-hex!
  "Appends the lowercase hex of bytes `b` to StringBuilder `sb`."
  [^StringBuilder sb ^bytes b]
  (let [n (alength b)
        ^chars digits digits]
    (loop [i 0]
      (when (< i n)
        (let [x (bit-and (aget b i) 0xff)]
          (.append sb (aget digits (unsigned-bit-shift-right x 4)))
          (.append sb (aget digits (bit-and x 15))))
        (recur (inc i)))))
  sb)

(defn bytes->hex
  "Lowercase hex string of byte array `b`."
  ^String [^bytes b]
  (str (append-hex! (StringBuilder. (* 2 (alength b))) b)))

(defn- nibble ^long [^long c]
  (cond (and (>= c 48) (<= c 57)) (- c 48)
        (and (>= c 97) (<= c 102)) (- c 87)
        :else (err/fail "invalid hex digit")))

(defn hex->bytes
  "Decodes the lowercase hex digits of `s` between `start` (inclusive) and
  `end` (exclusive) into a byte array. Throws on an odd count or any
  character that is not 0-9a-f."
  (^bytes [^String s] (hex->bytes s 0 (.length s)))
  (^bytes [^String s ^long start ^long end]
   (let [n (- end start)]
     (when (odd? n) (err/fail "odd number of hex digits"))
     (let [out (byte-array (quot n 2))]
       (loop [i 0]
         (when (< i (alength out))
           (let [p (+ start (* 2 i))
                 hi (nibble (code s p))
                 lo (nibble (code s (inc p)))]
             (aset out i (unchecked-byte (bit-or (bit-shift-left hi 4) lo))))
           (recur (inc i))))
       out))))
