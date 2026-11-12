(ns mime.bytes
  "Low-level helpers on byte arrays: line-ending normalisation, searching and
  the Adler-32 checksum.

  Everything here works on plain `byte[]` values and uses primitive loops, so
  it stays linear in the size of its input."
  (:import (java.util Arrays)))

(set! *warn-on-reflection* true)

(def ^:const LF 10)
(def ^:const CR 13)

(defn normalize-eol
  "Returns a copy of `b` in which every CR LF pair is replaced by a single LF.
  Nothing else changes: a CR that is not directly followed by LF is kept.
  Returns `b` itself when it contains no CR LF."
  ^bytes [^bytes b]
  (let [n (alength b)
        out (byte-array n)]
    (loop [i 0 o 0]
      (if (< i n)
        (let [x (aget b i)]
          (if (and (== x CR) (< (inc i) n) (== (aget b (inc i)) LF))
            (do (aset out o (byte LF)) (recur (+ i 2) (inc o)))
            (do (aset out o x) (recur (inc i) (inc o)))))
        (if (== o n) b (Arrays/copyOf out (int o)))))))

(defn index-of-lf
  "Index of the first LF in `b` at or after `from`, or `end` when there is none."
  ^long [^bytes b ^long from ^long end]
  (loop [i from]
    (cond (>= i end) end
          (== (aget b i) LF) i
          :else (recur (inc i)))))

(defn sub
  "Copy of `b` from `from` (inclusive) to `to` (exclusive)."
  ^bytes [^bytes b ^long from ^long to]
  (Arrays/copyOfRange b (int from) (int to)))

(defn adler32
  "Adler-32 checksum of `b` as an eight digit lower-case hexadecimal string."
  ^String [^bytes b]
  (let [n (alength b)]
    (loop [i 0 a 1 s 0]
      (if (< i n)
        (let [a' (rem (+ a (bit-and (aget b i) 0xff)) 65521)
              s' (rem (+ s a') 65521)]
          (recur (inc i) a' s'))
        (format "%08x" (+ (* s 65536) a))))))
