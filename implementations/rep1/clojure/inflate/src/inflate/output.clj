(ns inflate.output
  "Growable output buffer that doubles as the LZ77 history: back-references
  copy from the bytes already produced, across block boundaries."
  (:require [inflate.error :as err]))

(set! *warn-on-reflection* true)

(def ^:private ^:const max-array 2147483639)

(definterface IOutput
  (putByte [^long b])
  (putBytes [^bytes src ^long off ^long n])
  (copyMatch [^long dist ^long n])
  (^bytes toBytes []))

(deftype Output [^:unsynchronized-mutable ^bytes buf
                 ^:unsynchronized-mutable ^long len
                 ^long limit]
  IOutput
  (putByte [_ b]
    (when (== len (alength buf))
      (let [need (inc len)]
        (when (> need limit) (err/malformed! "output limit exceeded"))
        (set! buf (java.util.Arrays/copyOf buf (int (min limit (* 2 (alength buf))))))))
    (aset buf len (unchecked-byte b))
    (set! len (inc len)))
  (putBytes [_ src off n]
    (when (> (+ len n) (alength buf))
      (when (> (+ len n) limit) (err/malformed! "output limit exceeded"))
      (set! buf (java.util.Arrays/copyOf buf (int (min limit (max (+ len n) (* 2 (alength buf))))))))
    (System/arraycopy src off buf len n)
    (set! len (+ len n)))
  (copyMatch [_ dist n]
    (when (> dist len)
      (err/malformed! "distance beyond start of output"))
    (when (> (+ len n) (alength buf))
      (when (> (+ len n) limit) (err/malformed! "output limit exceeded"))
      (set! buf (java.util.Arrays/copyOf buf (int (min limit (max (+ len n) (* 2 (alength buf))))))))
    (let [from (- len dist)]
      (if (>= dist n)
        (System/arraycopy buf from buf len n)
        ;; Overlapping: must replicate byte by byte.
        (loop [i 0]
          (when (< i n)
            (aset buf (+ len i) (aget buf (+ from i)))
            (recur (inc i))))))
    (set! len (+ len n)))
  (toBytes [_]
    (java.util.Arrays/copyOf buf (int len))))

(defn output
  "Creates an output buffer with the given initial capacity, which will refuse
  to grow beyond `limit` bytes."
  ^Output [^long initial-capacity ^long limit]
  (let [limit (min limit max-array)]
    (Output. (byte-array (max 16 (min initial-capacity limit))) 0 limit)))

(defn put-byte! [^Output o ^long b] (.putByte o b))
(defn put-bytes! [^Output o ^bytes src ^long off ^long n] (.putBytes o src off n))
(defn copy-match!
  "Appends `n` bytes copied from `dist` bytes back; the regions may overlap."
  [^Output o ^long dist ^long n]
  (.copyMatch o dist n))
(defn ->bytes
  "A fresh byte array holding everything written so far."
  ^bytes [^Output o]
  (.toBytes o))
