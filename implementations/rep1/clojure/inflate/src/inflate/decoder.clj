(ns inflate.decoder
  "Block-level DEFLATE decoding: stored, fixed-Huffman and dynamic-Huffman
  blocks, driven by `inflate-stream`."
  (:require [inflate.bits :as bits]
            [inflate.error :as err]
            [inflate.huffman :as huff]
            [inflate.output :as out]
            [inflate.tables :as t])
  (:import (inflate.bits BitReader)
           (inflate.output Output)))

(set! *warn-on-reflection* true)

(def ^:private ^:const lit-root 10)
(def ^:private ^:const dist-root 8)
(def ^:private ^:const cl-root 7)

(defn- fixed-lit-lengths ^ints []
  (let [a (int-array 288)]
    (dotimes [i 288]
      (aset a i (int (cond (< i 144) 8 (< i 256) 9 (< i 280) 7 :else 8))))
    a))

(def ^:private ^ints fixed-lit (huff/build (fixed-lit-lengths) 0 288 lit-root {}))
(def ^:private ^ints fixed-dist
  (let [a (int-array 32)]
    (java.util.Arrays/fill a 5)
    (huff/build a 0 32 dist-root {})))

(defn- inflate-codes
  "Decodes literal/length and distance symbols until end-of-block."
  [^BitReader br ^Output o ^ints lit ^ints dist]
  (loop []
    (let [sym (huff/decode br lit lit-root)]
      (cond
        (< sym 256) (do (out/put-byte! o sym) (recur))
        (== sym 256) nil
        (> sym 285) (err/malformed! "invalid literal/length symbol")
        :else
        (let [i (- sym 257)
              len (+ (aget t/length-base i) (bits/read-bits br (aget t/length-extra i)))
              dsym (huff/decode br dist dist-root)]
          (when (> dsym 29) (err/malformed! "invalid distance symbol"))
          (let [d (+ (aget t/dist-base dsym) (bits/read-bits br (aget t/dist-extra dsym)))]
            (out/copy-match! o d len)
            (recur)))))))

(defn- inflate-stored [^BitReader br ^Output o]
  (bits/align! br)
  (let [len (bits/read-bits br 16)
        nlen (bits/read-bits br 16)]
    (when-not (== (bit-xor len nlen) 0xFFFF)
      (err/malformed! "stored block LEN/NLEN mismatch"))
    (let [start (bits/take-bytes! br len)]
      (out/put-bytes! o (bits/data br) start len))))

(defn- read-code-lengths
  "Reads the `total` literal/length + distance code lengths of a dynamic block."
  ^"[I" [^BitReader br ^ints cl-table ^long total]
  (let [lens (int-array total)]
    (loop [i 0]
      (when (< i total)
        (let [sym (huff/decode br cl-table cl-root)]
          (if (< sym 16)
            (do (aset lens i sym) (recur (inc i)))
            (let [[v rep] (case sym
                            16 (do (when (zero? i) (err/malformed! "repeat with no previous length"))
                                   [(aget lens (dec i)) (+ 3 (bits/read-bits br 2))])
                            17 [0 (+ 3 (bits/read-bits br 3))]
                            18 [0 (+ 11 (bits/read-bits br 7))])
                  rep (long rep)]
              (when (> (+ i rep) total) (err/malformed! "code length repeat overflows"))
              (java.util.Arrays/fill lens (int i) (int (+ i rep)) (int v))
              (recur (+ i rep)))))))
    lens))

(defn- inflate-dynamic [^BitReader br ^Output o]
  (let [hlit (+ 257 (bits/read-bits br 5))
        hdist (+ 1 (bits/read-bits br 5))
        hclen (+ 4 (bits/read-bits br 4))]
    (when (or (> hlit 286) (> hdist 30))
      (err/malformed! "too many length or distance codes"))
    (let [cl-lens (int-array 19)]
      (dotimes [i hclen]
        (aset cl-lens (aget t/code-length-order i) (int (bits/read-bits br 3))))
      (let [cl-table (huff/build cl-lens 0 19 cl-root {})
            ^ints lens (read-code-lengths br cl-table (+ hlit hdist))]
        (when (zero? (aget lens 256))
          (err/malformed! "no end-of-block code"))
        (inflate-codes br o
                       (huff/build lens 0 hlit lit-root {:single-ok? true})
                       (huff/build lens hlit hdist dist-root {:single-ok? true :empty-ok? true}))))))

(defn inflate-stream
  "Decodes the DEFLATE stream in the byte array `data` and returns the output
  as a byte array. Options: `:max-output` (default 2^31-9) bounds the size of
  the result. Throws a malformed-stream error (see `inflate.error`) if the
  stream is invalid, truncated, or followed by trailing bytes."
  ^bytes [^bytes data {:keys [max-output] :or {max-output Long/MAX_VALUE}}]
  (let [br (bits/reader data)
        o (out/output (* 4 (alength data)) max-output)]
    (loop []
      (let [final (bits/read-bits br 1)
            type (bits/read-bits br 2)]
        (case type
          0 (inflate-stored br o)
          1 (inflate-codes br o fixed-lit fixed-dist)
          2 (inflate-dynamic br o)
          (err/malformed! "invalid block type"))
        (when (zero? final) (recur))))
    (when (pos? (bits/remaining-bytes br))
      (err/malformed! "trailing data after final block"))
    (out/->bytes o)))
