(ns webhooks.bytes
  "Small helpers for working with byte arrays."
  (:import (java.nio.charset StandardCharsets)))

(set! *warn-on-reflection* true)

(defn concat-bytes
  "Concatenates any number of byte arrays into a new byte array."
  ^bytes [& arrays]
  (let [total (long (reduce + 0 (map #(alength ^bytes %) arrays)))
        out (byte-array total)]
    (loop [as (seq arrays) pos 0]
      (when as
        (let [^bytes a (first as)
              n (alength a)]
          (System/arraycopy a 0 out pos n)
          (recur (next as) (+ pos n)))))
    out))

(defn utf8
  "The UTF-8 encoding of string `s`."
  ^bytes [^String s]
  (.getBytes s StandardCharsets/UTF_8))

(defn ascii
  "The bytes of an ASCII (or Latin-1) string, one byte per character."
  ^bytes [^String s]
  (.getBytes s StandardCharsets/ISO_8859_1))

(defn latin1-string
  "Interprets each byte of `bs` as one character (0-255)."
  ^String [^bytes bs]
  (String. bs StandardCharsets/ISO_8859_1))
