(ns inflate.core-test
  (:require [clojure.test :refer [deftest is testing are]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [inflate.core :as core]
            [inflate.hex :as hex])
  (:import (java.util.zip Deflater)))

;;; Test helpers -------------------------------------------------------------

(defn pack
  "Packs fields into hex, LSB first. A field is [value nbits] (numeric field)
  or [:code value nbits] (Huffman code, sent most significant bit first)."
  [& fields]
  (let [bits (mapcat (fn [f]
                       (if (= :code (first f))
                         (let [[_ v n] f] (for [i (range (dec n) -1 -1) ] (bit-and 1 (bit-shift-right v i))))
                         (let [[v n] f] (for [i (range n)] (bit-and 1 (bit-shift-right v i))))))
                     fields)
        bytes (for [chunk (partition-all 8 bits)]
                (reduce + (map-indexed (fn [i b] (bit-shift-left b i)) chunk)))]
    (hex/encode (byte-array (map unchecked-byte bytes)))))

(defn- malformed? [h & [opts]]
  (try (core/inflate-hex h (or opts {})) false
       (catch clojure.lang.ExceptionInfo e (core/malformed? e))))

(def eob-fixed [:code 0 7])
(defn lit-fixed [b] [:code (+ 0x30 b) 8])   ; for literals 0..143

;;; Examples from SPEC.md ----------------------------------------------------

(deftest spec-examples
  (are [in out] (= out (core/inflate-hex in))
    "0300" ""
    "010100feff41" "41"
    "4b4c4a862000" "616263616263616263")
  (is (malformed? "030200")))

;;; Hand-built streams ---------------------------------------------------------

(deftest stored-blocks
  (is (= "" (core/inflate-hex "010000ffff")))
  (is (= "4142" (core/inflate-hex "000100feff41010100feff42")))
  (testing "padding bits after the header are not checked"
    (is (= "41" (core/inflate-hex "f90100feff41"))))
  (testing "non-final empty block followed by a fixed block"
    (is (= "" (core/inflate-hex (str "000000ffff" "0300"))))))

(deftest fixed-block-overlapping-copy
  ;; 'a', then copy length 258 (symbol 285) from distance 1.
  (is (= (apply str (repeat 259 "61"))
         (core/inflate-hex (pack [1 1] [1 2] (lit-fixed 97)
                                 [:code 0xC5 8] [0 5] eob-fixed)))))

(deftest length-258-via-symbol-284
  (is (= (apply str (repeat 259 "61"))
         (core/inflate-hex (pack [1 1] [1 2] (lit-fixed 97)
                                 [:code (+ 0xC0 4) 8] [31 5] [0 5] eob-fixed)))))

(deftest dynamic-block
  (let [stream (pack [1 1] [2 2] [0 5] [0 5] [14 4]
                     ;; code-length code lengths in order 16 17 18 0 8 7 9 6 10 5 11 4 12 3 13 2 14 1
                     [0 3] [0 3] [1 3] [2 3] [0 3] [0 3] [0 3] [0 3] [0 3]
                     [0 3] [0 3] [0 3] [0 3] [0 3] [0 3] [0 3] [0 3] [2 3]
                     ;; lengths: 97 zeros, 1, 158 zeros, 1 (256), one zero distance length
                     [:code 0 1] [86 7] [:code 3 2]
                     [:code 0 1] [127 7] [:code 0 1] [9 7] [:code 3 2] [:code 2 2]
                     ;; data: 'a' 'a' end-of-block (codes 0, 0, 1)
                     [:code 0 1] [:code 0 1] [:code 1 1])]
    (is (= "6161" (core/inflate-hex stream)))
    (testing "a back-reference needs a distance code"
      (is (not (malformed? stream))))))

(deftest malformed-streams
  (are [h] (malformed? h)
    ""                       ; empty stream
    "00"                     ; ends inside stored header
    "0100"                   ; truncated LEN
    "010100fe"               ; truncated NLEN
    "010200fdff41"           ; truncated stored data
    "010100ffff41"           ; LEN/NLEN mismatch
    "07"                     ; BTYPE 3
    "000000ffff"             ; non-final block, then nothing
    "03"                     ; fixed block, truncated before end-of-block
    "0300ff"                 ; trailing byte
    "010000ffff00")          ; trailing byte after stored block
  (testing "invalid symbols"
    (is (malformed? (pack [1 1] [1 2] [:code 0xC6 8])))           ; length symbol 286
    (is (malformed? (pack [1 1] [1 2] (lit-fixed 97) [:code 1 7] [:code 30 5] eob-fixed)))   ; distance symbol 30
    (is (not (malformed? (pack [1 1] [1 2] (lit-fixed 97) [:code 1 7] [:code 0 5] eob-fixed)))))
  (testing "dynamic header limits"
    (is (malformed? (pack [1 1] [2 2] [30 5] [0 5] [0 4])))      ; HLIT 30
    (is (malformed? (pack [1 1] [2 2] [0 5] [30 5] [0 4])))      ; HDIST 30
    (is (malformed? (pack [1 1] [2 2] [0 5] [0 5] [0 4] [0 12]))))) ; empty cl code

(deftest max-output-limit
  (let [h (pack [1 1] [1 2] (lit-fixed 97) [:code 0xC5 8] [0 5] eob-fixed)]
    (is (= 259 (/ (count (core/inflate-hex h {:max-output 259})) 2)))
    (is (malformed? h {:max-output 100}))))

(deftest hex-garbage-is-not-a-malformed-stream
  (is (thrown? IllegalArgumentException (core/inflate-hex "xyz0"))))

;;; Round trips against java.util.zip.Deflater (compression only) ------------------

(defn deflate
  "Raw DEFLATE of `data` using the JDK's compressor."
  [^bytes data level strategy]
  (let [d (doto (Deflater. level true) (.setStrategy strategy))
        out (java.io.ByteArrayOutputStream.)
        buf (byte-array 8192)]
    (.setInput d data)
    (.finish d)
    ;; A strategy change makes the first call emit only a partial result.
    (while (not (.finished d))
      (.write out buf 0 (.deflate d buf)))
    (.end d)
    (.toByteArray out)))

(def gen-data
  "Byte arrays mixing random bytes with repeated runs, so matches occur."
  (gen/fmap (fn [chunks] (byte-array (mapcat identity chunks)))
            (gen/vector
             (gen/one-of
              [(gen/vector gen/byte 0 40)
               (gen/fmap (fn [[b n]] (repeat n b)) (gen/tuple gen/byte (gen/choose 1 300)))])
             0 60)))

(defspec round-trip 200
  (prop/for-all [data gen-data
                 level (gen/choose 0 9)
                 strategy (gen/elements [Deflater/DEFAULT_STRATEGY Deflater/FILTERED
                                         Deflater/HUFFMAN_ONLY])]
    (= (vec data) (vec (core/inflate (deflate data level strategy))))))

(deftest round-trip-large
  (let [data (byte-array (for [i (range 300000)] (unchecked-byte (* (mod i 251) (mod (quot i 7) 13)))))]
    (doseq [level [0 1 6 9]]
      (is (= (vec data) (vec (core/inflate (deflate data level Deflater/DEFAULT_STRATEGY))))))))

(defspec truncation-never-succeeds 100
  ;; Cutting a stream short must either fail or (when only padding is cut)
  ;; yield the same data; it must never throw anything but a malformed error.
  (prop/for-all [data gen-data
                 cut gen/nat]
    (let [z (deflate data 6 Deflater/DEFAULT_STRATEGY)
          k (min cut (max 0 (dec (alength z))))
          short (java.util.Arrays/copyOf z (int k))]
      (try (core/inflate short) false
           (catch clojure.lang.ExceptionInfo e (core/malformed? e))))))
