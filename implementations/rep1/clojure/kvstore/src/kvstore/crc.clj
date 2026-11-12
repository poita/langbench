(ns kvstore.crc
  "CRC-32 (reflected polynomial 0xEDB88320, init and final xor 0xFFFFFFFF),
  table driven.  Written from scratch as the Tessera formats require."
  (:require [kvstore.bytes :as b]))

(set! *warn-on-reflection* true)

(def ^:private ^"[J" table
  (let [^longs t (long-array 256)]
    (dotimes [n 256]
      (aset t n
            (long (loop [c (long n) k 0]
              (if (< k 8)
                (recur (if (odd? c)
                         (bit-xor (unsigned-bit-shift-right c 1) 0xEDB88320)
                         (unsigned-bit-shift-right c 1))
                       (inc k))
                c)))))
    t))

(def init
  "Initial running CRC state."
  0xFFFFFFFF)

(defn update-crc
  "Fold `len` bytes of `buf` starting at `off` into the running state `crc`."
  ^long [^long crc ^bytes buf ^long off ^long len]
  (let [end (+ off len)]
    (loop [c crc i off]
      (if (< i end)
        (recur (bit-xor (aget table (bit-and (bit-xor c (b/u8 buf i)) 0xFF))
                        (unsigned-bit-shift-right c 8))
               (inc i))
        c))))

(defn finish
  "Final xor turning a running state into the checksum."
  ^long [^long crc]
  (bit-xor crc 0xFFFFFFFF))

(defn crc32
  "CRC-32 of a byte array (or of a sub-range)."
  (^long [^bytes buf] (crc32 buf 0 (alength buf)))
  (^long [^bytes buf ^long off ^long len]
   (finish (update-crc init buf off len))))
