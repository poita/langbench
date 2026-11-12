(ns kvstore.bytes
  "Small helpers for working with byte arrays: big-endian integer access,
  unsigned lexicographic comparison and UTF-8 conversion.  All multi-byte
  integers in the Tessera file formats are unsigned big-endian."
  (:import (java.nio.charset StandardCharsets)
           (java.util Arrays)))

(set! *warn-on-reflection* true)

(defn u8
  "Unsigned byte at index `i`."
  ^long [^bytes b ^long i]
  (bit-and 0xFF (long (aget b i))))

(defn u16
  "Unsigned big-endian 16-bit integer at index `i`."
  ^long [^bytes b ^long i]
  (bit-or (bit-shift-left (u8 b i) 8) (u8 b (inc i))))

(defn u32
  "Unsigned big-endian 32-bit integer at index `i`."
  ^long [^bytes b ^long i]
  (bit-or (bit-shift-left (u8 b i) 24)
          (bit-shift-left (u8 b (+ i 1)) 16)
          (bit-shift-left (u8 b (+ i 2)) 8)
          (u8 b (+ i 3))))

(defn u64
  "Big-endian 64-bit integer at index `i` (as a signed long; the bit pattern
  is what matters)."
  ^long [^bytes b ^long i]
  (bit-or (bit-shift-left (u32 b i) 32) (u32 b (+ i 4))))

(defn put-u8! [^bytes b ^long i ^long v]
  (aset-byte b i (unchecked-byte v)))

(defn put-u16! [^bytes b ^long i ^long v]
  (aset-byte b i (unchecked-byte (bit-shift-right v 8)))
  (aset-byte b (inc i) (unchecked-byte v)))

(defn put-u32! [^bytes b ^long i ^long v]
  (aset-byte b i (unchecked-byte (bit-shift-right v 24)))
  (aset-byte b (+ i 1) (unchecked-byte (bit-shift-right v 16)))
  (aset-byte b (+ i 2) (unchecked-byte (bit-shift-right v 8)))
  (aset-byte b (+ i 3) (unchecked-byte v)))

(defn put-u64! [^bytes b ^long i ^long v]
  (put-u32! b i (bit-and 0xFFFFFFFF (bit-shift-right v 32)))
  (put-u32! b (+ i 4) (bit-and 0xFFFFFFFF v)))

(defn put-bytes!
  "Copy all of `src` into `dst` starting at `off`."
  [^bytes dst ^long off ^bytes src]
  (System/arraycopy src 0 dst off (alength src)))

(defn compare-bytes
  "Unsigned lexicographic comparison; a proper prefix sorts first."
  ^long [^bytes a ^bytes b]
  (long (Arrays/compareUnsigned a b)))

(defn bytes=
  [^bytes a ^bytes b]
  (Arrays/equals a b))

(defn prefix?
  "True when `p` is a prefix of `b`."
  [^bytes p ^bytes b]
  (and (<= (alength p) (alength b))
       (zero? (Arrays/compareUnsigned p 0 (alength p) b 0 (alength p)))))

(defn sub
  "Copy of `b` from `from` (inclusive) to `to` (exclusive)."
  ^bytes [^bytes b ^long from ^long to]
  (Arrays/copyOfRange b (int from) (int to)))

(defn concat-bytes
  "Concatenate byte arrays."
  ^bytes [& arrays]
  (let [total (reduce + 0 (map #(alength ^bytes %) arrays))
        out (byte-array total)]
    (loop [off 0 [^bytes a & more] arrays]
      (when a
        (System/arraycopy a 0 out off (alength a))
        (recur (+ off (alength a)) more)))
    out))

(defn utf8
  "UTF-8 encoding of a string."
  ^bytes [^String s]
  (.getBytes s StandardCharsets/UTF_8))

(defn from-utf8
  "Decode UTF-8 bytes to a string."
  ^String [^bytes b]
  (String. b StandardCharsets/UTF_8))

(defn hex
  "Lower-case hex rendering of a byte array (handy in tests and the REPL)."
  [^bytes b]
  (apply str (map #(format "%02x" (bit-and 0xFF (long %))) b)))

(defn unhex
  "Inverse of `hex`; whitespace is ignored."
  ^bytes [^String s]
  (let [s (.replaceAll s "\\s" "")
        out (byte-array (quot (count s) 2))]
    (dotimes [i (alength out)]
      (aset-byte out i (unchecked-byte (Integer/parseInt (subs s (* 2 i) (+ 2 (* 2 i))) 16))))
    out))
