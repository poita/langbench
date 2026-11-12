(ns inflate.bits
  "LSB-first bit reader over a byte array, as DEFLATE requires.

  Bits are buffered in a 64-bit word. `peek-bits` may look past the end of the
  data (missing bits read as zero) but `drop-bits` refuses to consume bits
  that do not exist."
  (:require [inflate.error :as err]))

(set! *warn-on-reflection* true)

(definterface IBitReader
  (^long peekBits [^long n])
  (dropBits [^long n])
  (^long readBits [^long n])
  (alignToByte [])
  (^long takeBytes [^long n])
  (^long remainingBytes []))

(deftype BitReader [^bytes data
                    ^long len
                    ^:unsynchronized-mutable ^long pos
                    ^:unsynchronized-mutable ^long buf
                    ^:unsynchronized-mutable ^long cnt]
  IBitReader
  (peekBits [_ n]
    (when (< cnt n)
      (loop []
        (when (and (<= cnt 48) (< pos len))
          (set! buf (bit-or buf (bit-shift-left (bit-and (long (aget data pos)) 0xff) cnt)))
          (set! pos (inc pos))
          (set! cnt (+ cnt 8))
          (recur))))
    (bit-and buf (dec (bit-shift-left 1 n))))
  (dropBits [_ n]
    (when (> n cnt)
      (err/malformed! "unexpected end of stream"))
    (set! buf (unsigned-bit-shift-right buf n))
    (set! cnt (- cnt n)))
  (readBits [this n]
    (let [v (.peekBits this n)]
      (.dropBits this n)
      v))
  (alignToByte [this]
    (.dropBits this (bit-and cnt 7)))
  (takeBytes [_ n]
    ;; Precondition: byte aligned. Give back whole buffered bytes, then hand
    ;; out the offset of the next n bytes of `data`.
    (let [start (- pos (bit-shift-right cnt 3))]
      (when (> (+ start n) len)
        (err/malformed! "unexpected end of stream"))
      (set! pos (+ start n))
      (set! buf 0)
      (set! cnt 0)
      start))
  (remainingBytes [_]
    ;; Whole bytes after the byte holding the last consumed bit.
    (+ (- len pos) (bit-shift-right cnt 3))))

(defn reader
  "Creates a bit reader positioned at the start of the byte array `data`."
  ^BitReader [^bytes data]
  (BitReader. data (alength data) 0 0 0))

(defn peek-bits
  "The next `n` (<= 32) bits without consuming them, zero-padded past the end."
  ^long [^BitReader br ^long n]
  (.peekBits br n))

(defn drop-bits
  "Consumes `n` bits; throws a malformed-stream error if fewer remain."
  [^BitReader br ^long n]
  (.dropBits br n))

(defn read-bits
  "Consumes and returns an `n`-bit (<= 32) number, first bit least significant."
  ^long [^BitReader br ^long n]
  (.readBits br n))

(defn align!
  "Discards the bits left in the current byte."
  [^BitReader br]
  (.alignToByte br))

(defn take-bytes!
  "Byte-aligned: consumes the next `n` whole bytes and returns their offset in
  the underlying array (see `data`)."
  ^long [^BitReader br ^long n]
  (.takeBytes br n))

(defn data
  "The byte array a reader reads from."
  ^bytes [^BitReader br]
  (.-data br))

(defn remaining-bytes
  "Number of whole bytes following the last bit consumed so far."
  ^long [^BitReader br]
  (.remainingBytes br))
