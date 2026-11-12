(ns mime.charset
  "Character set decoding: bytes to Java strings.

  Only four tables are supported (ASCII, UTF-8, Latin-1 and cp1252); every
  other name falls back to cp1252. UTF-8 is decoded by hand, replacing invalid
  input with U+FFFD by the maximal-subpart rule."
  (:require [mime.text :as text])
  (:import (java.nio.charset StandardCharsets)))

(set! *warn-on-reflection* true)

(def ^:private ascii-names
  #{"us-ascii" "ascii" "iso-ir-6" "ansi_x3.4-1968" "iso646-us"})

(def ^:private utf8-names
  #{"utf-8" "utf8" "unicode-1-1-utf-8"})

(def ^:private latin1-names
  #{"iso-8859-1" "iso8859-1" "latin-1" "latin1" "l1" "8859-1" "iso_8859-1"})

(def ^:private ^"[I" cp1252-high
  "Code points for the bytes 0x80-0x9F in cp1252."
  (int-array [0x20AC 0x0081 0x201A 0x0192 0x201E 0x2026 0x2020 0x2021
              0x02C6 0x2030 0x0160 0x2039 0x0152 0x008D 0x017D 0x008F
              0x0090 0x2018 0x2019 0x201C 0x201D 0x2022 0x2013 0x2014
              0x02DC 0x2122 0x0161 0x203A 0x0153 0x009D 0x017E 0x0178]))

(defn normalize-name
  "Normalised charset name: blanks stripped, ASCII letters lower-cased."
  ^String [^String name]
  (text/ascii-lower (text/strip name)))

(defn encode-utf8
  "UTF-8 bytes of the string `s`."
  ^bytes [^String s]
  (.getBytes s StandardCharsets/UTF_8))

(defn decode-ascii
  "Bytes below 0x80 map to themselves, all others to U+FFFD."
  ^String [^bytes b]
  (let [n (alength b) sb (StringBuilder. n)]
    (dotimes [i n]
      (let [x (bit-and (aget b i) 0xff)]
        (.append sb (if (< x 0x80) (char x) \uFFFD))))
    (.toString sb)))

(defn decode-latin1
  "Every byte maps to the code point of the same value."
  ^String [^bytes b]
  (let [n (alength b) sb (StringBuilder. n)]
    (dotimes [i n]
      (.append sb (char (bit-and (aget b i) 0xff))))
    (.toString sb)))

(defn decode-cp1252
  "Windows-1252: Latin-1 except that 0x80-0x9F go through a table."
  ^String [^bytes b]
  (let [n (alength b) sb (StringBuilder. n)]
    (dotimes [i n]
      (let [x (bit-and (aget b i) 0xff)]
        (.append sb (char (if (and (>= x 0x80) (< x 0xA0))
                            (aget cp1252-high (- x 0x80))
                            x)))))
    (.toString sb)))

(defn- continuation-ok?
  [^bytes b ^long pos ^long lo ^long hi]
  (and (< pos (alength b))
       (let [c (bit-and (aget b pos) 0xff)]
         (and (>= c lo) (<= c hi)))))

(defn- decode-sequence!
  "Decodes the multi-byte sequence starting at `i` (lead byte `b0` >= 0x80),
  appends its result to `sb` and returns the index of the next unread byte."
  ^long [^StringBuilder sb ^bytes b ^long i ^long b0]
  (let [n (alength b)
        [len lo hi]
        (cond (and (>= b0 0xC2) (<= b0 0xDF)) [2 0x80 0xBF]
              (== b0 0xE0) [3 0xA0 0xBF]
              (and (>= b0 0xE1) (<= b0 0xEC)) [3 0x80 0xBF]
              (== b0 0xED) [3 0x80 0x9F]
              (and (>= b0 0xEE) (<= b0 0xEF)) [3 0x80 0xBF]
              (== b0 0xF0) [4 0x90 0xBF]
              (and (>= b0 0xF1) (<= b0 0xF3)) [4 0x80 0xBF]
              (== b0 0xF4) [4 0x80 0x8F]
              :else nil)]
    (if (nil? len)
      (do (.append sb \uFFFD) (inc i))
      (let [len (long len) lo (long lo) hi (long hi)
            mask (case (int len) 2 0x1F 3 0x0F 4 0x07)]
        (loop [k 1 cp (bit-and b0 mask)]
          (if (== k len)
            (do (.appendCodePoint sb (int cp)) (+ i len))
            (if (if (== k 1)
                  (continuation-ok? b (+ i k) lo hi)
                  (continuation-ok? b (+ i k) 0x80 0xBF))
              (recur (inc k) (bit-or (bit-shift-left cp 6)
                                     (bit-and (aget b (+ i k)) 0x3f)))
              (do (.append sb \uFFFD) (+ i k)))))))))

(defn decode-utf8
  "Decodes `b` as UTF-8, replacing invalid input with U+FFFD by the
  maximal-subpart rule: a truncated or invalid sequence yields one U+FFFD for
  the bytes of it that were valid, and the offending byte is read again."
  ^String [^bytes b]
  (let [n (alength b)
        sb (StringBuilder. n)]
    (loop [i 0]
      (when (< i n)
        (let [b0 (bit-and (aget b i) 0xff)]
          (if (< b0 0x80)
            (do (.append sb (char b0)) (recur (inc i)))
            (recur (decode-sequence! sb b i b0))))))
    (.toString sb)))

(defn decode
  "Decodes `b` using the character set called `charset` (any string, an
  unknown or empty name means cp1252). Returns a string."
  ^String [^bytes b ^String charset]
  (let [name (normalize-name charset)]
    (cond (contains? utf8-names name) (decode-utf8 b)
          (contains? ascii-names name) (decode-ascii b)
          (contains? latin1-names name) (decode-latin1 b)
          :else (decode-cp1252 b))))
