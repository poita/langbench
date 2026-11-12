(ns mime.transfer
  "Content-Transfer-Encoding decoders: quoted-printable and base64, both
  written by hand and both lenient (malformed input never throws)."
  (:require [mime.text :as text])
  (:import (java.util Arrays)))

(set! *warn-on-reflection* true)

(def ^:private ^"[I" b64-table
  "Maps a byte value to its base64 sextet, or -1 when it is not in the alphabet."
  (let [t (int-array 256 -1)
        alphabet "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"]
    (dotimes [i 64] (aset t (int (.charAt ^String alphabet i)) (int i)))
    t))

(defn decode-base64
  "Decodes base64 from the bytes `b`. Every byte outside the alphabet
  (including `=`) is discarded first; a trailing group of 2 or 3 characters
  yields 1 or 2 bytes and a trailing single character is dropped."
  ^bytes [^bytes b]
  (let [n (alength b)
        out (byte-array (+ 3 (quot (* n 3) 4)))]
    (loop [i 0 acc 0 cnt 0 o 0]
      (if (< i n)
        (let [v (aget b64-table (bit-and (aget b i) 0xff))]
          (if (neg? v)
            (recur (inc i) acc cnt o)
            (let [acc (bit-or (bit-shift-left acc 6) v)
                  cnt (inc cnt)]
              (if (== cnt 4)
                (do (aset out o (unchecked-byte (bit-shift-right acc 16)))
                    (aset out (+ o 1) (unchecked-byte (bit-shift-right acc 8)))
                    (aset out (+ o 2) (unchecked-byte acc))
                    (recur (inc i) 0 0 (+ o 3)))
                (recur (inc i) acc cnt o)))))
        (case (int cnt)
          2 (do (aset out o (unchecked-byte (bit-shift-right acc 4)))
                (Arrays/copyOf out (int (inc o))))
          3 (do (aset out o (unchecked-byte (bit-shift-right acc 10)))
                (aset out (inc o) (unchecked-byte (bit-shift-right acc 2)))
                (Arrays/copyOf out (int (+ o 2))))
          (Arrays/copyOf out (int o)))))))

(defn decode-base64-string
  "Like [[decode-base64]] but reads the characters of the string `s`;
  characters outside the base64 alphabet (including all non-ASCII ones) are
  discarded."
  ^bytes [^String s]
  (let [n (.length s)
        b (byte-array n)]
    (dotimes [i n]
      (let [c (int (.charAt s i))]
        (aset b i (if (< c 128) (unchecked-byte c) (byte 0x2D))))) ; '-' is not in the alphabet
    (decode-base64 b)))

(defn decode-quoted-printable
  "Decodes quoted-printable from `b` (line endings already normalised to LF).

  `=` followed by LF is a soft line break; `=` and two hex digits is that
  byte; a final `=` is dropped; any other `=` is literal. Everything else,
  including trailing blanks, is copied unchanged."
  ^bytes [^bytes b]
  (let [n (alength b)
        out (byte-array n)]
    (loop [i 0 o 0]
      (if (< i n)
        (let [x (aget b i)]
          (if (== x 61)
            (cond
              (>= (inc i) n) (Arrays/copyOf out (int o)) ; `=` is the last byte
              (== (aget b (inc i)) 10) (recur (+ i 2) o)
              (and (< (+ i 2) n)
                   (>= (text/hex-val (bit-and (aget b (inc i)) 0xff)) 0)
                   (>= (text/hex-val (bit-and (aget b (+ i 2)) 0xff)) 0))
              (do (aset out o (unchecked-byte
                               (+ (* 16 (text/hex-val (bit-and (aget b (inc i)) 0xff)))
                                  (text/hex-val (bit-and (aget b (+ i 2)) 0xff)))))
                  (recur (+ i 3) (inc o)))
              :else (do (aset out o x) (recur (inc i) (inc o))))
            (do (aset out o x) (recur (inc i) (inc o)))))
        (Arrays/copyOf out (int o))))))

(defn decode-body
  "Decodes the transfer-encoded body `b` according to the encoding token
  `encoding` (already lower-cased). Unknown encodings, and `7bit`, `8bit`
  and `binary`, return `b` unchanged."
  ^bytes [^bytes b ^String encoding]
  (case encoding
    "base64" (decode-base64 b)
    "quoted-printable" (decode-quoted-printable b)
    b))
