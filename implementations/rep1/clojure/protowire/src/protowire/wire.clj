(ns protowire.wire
  "Low-level wire-format primitives over byte arrays.

  Readers keep their position in a one-element `long[]` cursor (`pos`, with
  the position in element 0) and take an explicit exclusive `end` limit, so
  reading a sub-message just means passing a smaller `end`. Writers take and
  return an explicit position."
  (:require [protowire.error :as err]))

(set! *warn-on-reflection* true)
(set! *unchecked-math* true)

;; ---------------------------------------------------------------- reading

(defn read-varint
  "Reads a base-128 varint of at most `max-bytes` bytes at the cursor, not
  reading at or beyond `end`. Returns its value modulo 2^64 as a long and
  advances the cursor."
  ^long [^bytes buf ^longs pos ^long end ^long max-bytes]
  (loop [p (aget pos 0) shift 0 acc 0 n 1]
    (when (>= p end) (err/fail "truncated varint"))
    (let [b (long (bit-and (aget buf p) 0xff))
          acc (bit-or acc (bit-shift-left (bit-and b 0x7f) shift))
          p (inc p)]
      (if (zero? (bit-and b 0x80))
        (do (aset pos 0 p) acc)
        (do (when (>= n max-bytes) (err/fail "varint too long"))
            (recur p (+ shift 7) acc (inc n)))))))

(defn read-tag
  "Reads a field tag: a varint of at most 5 bytes whose value is below 2^32.
  Returns the raw tag value."
  ^long [^bytes buf ^longs pos ^long end]
  (let [t (read-varint buf pos end 5)]
    (when (>= t 4294967296) (err/fail "tag too large"))
    t))

(defn read-length
  "Reads a length prefix (varint of at most 5 bytes) that must not exceed the
  bytes remaining before `end`. Returns the length."
  ^long [^bytes buf ^longs pos ^long end]
  (let [n (read-varint buf pos end 5)]
    (when (> n (- end (aget pos 0))) (err/fail "length exceeds remaining bytes"))
    n))

(defn skip-bytes!
  "Advances the cursor by `n` bytes, failing if fewer remain before `end`."
  [^longs pos ^long end ^long n]
  (let [p (aget pos 0)]
    (when (> n (- end p)) (err/fail "truncated data"))
    (aset pos 0 (+ p n))))

(defn read-fixed32
  "Reads 4 little-endian bytes as an unsigned value (0..2^32-1)."
  ^long [^bytes buf ^longs pos ^long end]
  (let [p (aget pos 0)]
    (skip-bytes! pos end 4)
    (bit-or (bit-and (aget buf p) 0xff)
            (bit-shift-left (bit-and (aget buf (+ p 1)) 0xff) 8)
            (bit-shift-left (bit-and (aget buf (+ p 2)) 0xff) 16)
            (bit-shift-left (bit-and (aget buf (+ p 3)) 0xff) 24))))

(defn read-fixed64
  "Reads 8 little-endian bytes as a 64-bit pattern."
  ^long [^bytes buf ^longs pos ^long end]
  (let [p (aget pos 0)]
    (skip-bytes! pos end 8)
    (loop [i 7 acc 0]
      (if (neg? i)
        acc
        (recur (dec i) (bit-or (bit-shift-left acc 8) (bit-and (aget buf (+ p i)) 0xff)))))))

;; ---------------------------------------------------------------- skipping

(defn skip-field!
  "Skips the payload of a field whose tag (field number `fnum`, wire type
  `wt`) has just been read, applying the same limits as normal decoding.
  Groups are skipped through to their matching end-group tag."
  [^bytes buf ^longs pos end fnum wt]
  (let [end (long end) fnum (long fnum) wt (long wt)]
  (case wt
    0 (read-varint buf pos end 10)
    1 (skip-bytes! pos end 8)
    2 (skip-bytes! pos end (read-length buf pos end))
    5 (skip-bytes! pos end 4)
    3 (loop []
        (let [tag (read-tag buf pos end)
              n (unsigned-bit-shift-right tag 3)
              w (bit-and tag 7)]
          (when (zero? n) (err/fail "field number 0"))
          (cond
            (= w 4) (when-not (= n fnum) (err/fail "mismatched end-group tag"))
            (or (= w 6) (= w 7)) (err/fail "invalid wire type")
            :else (do (skip-field! buf pos end n w) (recur)))))
    (err/fail "invalid wire type"))
  nil))

;; ---------------------------------------------------------------- writing

(defn varint-size
  "Number of bytes in the minimal varint encoding of the 64-bit pattern `v`."
  ^long [^long v]
  (max 1 (quot (+ (- 64 (Long/numberOfLeadingZeros v)) 6) 7)))

(defn write-varint!
  "Writes `v` (a 64-bit pattern) as a minimal varint at `pos`; returns the new
  position."
  ^long [^bytes out ^long pos ^long v]
  (loop [p pos v v]
    (if (zero? (unsigned-bit-shift-right v 7))
      (do (aset out p (unchecked-byte v)) (inc p))
      (do (aset out p (unchecked-byte (bit-or (bit-and v 0x7f) 0x80)))
          (recur (inc p) (unsigned-bit-shift-right v 7))))))

(defn write-fixed32!
  "Writes the low 32 bits of `v` little-endian; returns the new position."
  ^long [^bytes out ^long pos ^long v]
  (dotimes [i 4]
    (aset out (+ pos i) (unchecked-byte (unsigned-bit-shift-right v (* 8 i)))))
  (+ pos 4))

(defn write-fixed64!
  "Writes `v` as 8 little-endian bytes; returns the new position."
  ^long [^bytes out ^long pos ^long v]
  (dotimes [i 8]
    (aset out (+ pos i) (unchecked-byte (unsigned-bit-shift-right v (* 8 i)))))
  (+ pos 8))

(defn write-bytes!
  "Copies byte array `src` to `out` at `pos`; returns the new position."
  ^long [^bytes out ^long pos ^bytes src]
  (System/arraycopy src 0 out pos (alength src))
  (+ pos (alength src)))
