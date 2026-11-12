(ns qrcode.codewords
  "Turns a segment into the final codeword sequence: terminator and padding,
  block splitting, Reed-Solomon ECC and interleaving."
  (:require [qrcode.bits :as bits]
            [qrcode.reedsolomon :as rs]
            [qrcode.segment :as segment]
            [qrcode.tables :as tables]))

(set! *warn-on-reflection* true)

(defn data-codewords
  "Returns the `C(v, ecl)` data codewords (an int array) for the segment
  holding `data` in `mode`: segment, terminator, bit padding and pad bytes."
  ^ints [mode ^bytes data ^long v ecl]
  (let [cap (tables/data-codewords ecl v)
        buf (bits/buffer cap)]
    (segment/write-segment! buf mode data v)
    (bits/skip! buf (min 4 (- (bits/capacity buf) (bits/length buf))))
    (bits/skip! buf (mod (- (bits/length buf)) 8))
    (let [words (bits/codewords buf)]
      (loop [i (quot (bits/length buf) 8), pad 0xEC]
        (when (< i cap)
          (aset words i (int pad))
          (recur (inc i) (if (== pad 0xEC) 0x11 0xEC))))
      words)))

(defn interleave-blocks
  "Splits the int array of data codewords into blocks for version `v` at
  `ecl`, appends Reed-Solomon ECC to each, and returns the interleaved
  codeword sequence as an int array of length `T(v)`: data codewords column
  by column across blocks, then ECC codewords the same way."
  ^ints [^ints data ^long v ecl]
  (let [total (tables/total-codewords v)
        nblocks (tables/block-count ecl v)
        ecc-len (tables/ecc-codewords-per-block ecl v)
        nshort (- nblocks (rem total nblocks))
        short-len (- (quot total nblocks) ecc-len)
        data-total (- total (* nblocks ecc-len))
        result (int-array total)
        ;; Per block: data codewords and ECC codewords.
        blocks (loop [i 0, start 0, acc []]
                 (if (== i nblocks)
                   acc
                   (let [len (if (< i nshort) short-len (inc short-len))
                         d (java.util.Arrays/copyOfRange data (int start) (int (+ start len)))]
                     (recur (inc i) (+ start len)
                            (conj acc {:data d, :ecc (rs/remainder d ecc-len)})))))]
    (loop [j 0, k 0]
      (when (<= j short-len)
        (recur (inc j)
               (long (reduce (fn [k {:keys [^ints data]}]
                               (if (< j (alength data))
                                 (do (aset result (int k) (aget data j)) (inc k))
                                 k))
                             k blocks)))))
    (dotimes [j ecc-len]
      (dotimes [b nblocks]
        (aset result (+ data-total (* j nblocks) b)
              (aget ^ints (:ecc (nth blocks b)) j))))
    result))
