(ns gitrepo.delta
  "Git packfile delta application."
  (:require [gitrepo.error :as err]))

(set! *warn-on-reflection* true)

(defn- damaged [msg] (err/fail :damaged (str "delta: " msg)))

(defn apply-delta
  "Applies delta stream `delta` to byte array `base` and returns the result.
  Throws a `:damaged` failure if the delta is malformed, does not match the
  base size, copies outside the base, or produces the wrong result size."
  ^bytes [^bytes base ^bytes delta]
  (let [dlen (alength delta)
        varint (fn [^long pos]
                 (loop [pos pos shift 0 v 0]
                   (when (>= pos dlen) (damaged "truncated header"))
                   (let [b (bit-and 0xff (aget delta pos))
                         v (bit-or v (bit-shift-left (bit-and b 0x7f) shift))]
                     (if (zero? (bit-and b 0x80))
                       [v (inc pos)]
                       (do (when (> shift 56) (damaged "size too large"))
                           (recur (inc pos) (+ shift 7) v))))))
        [base-size p] (varint 0)
        [result-size p] (varint p)]
    (when-not (= base-size (alength base)) (damaged "base size mismatch"))
    (when (> result-size (- Integer/MAX_VALUE 16)) (damaged "result too large"))
    (let [out (byte-array (int result-size))
          blen (alength base)]
      (loop [pos (long p) o 0]
        (if (>= pos dlen)
          (when-not (= o result-size) (damaged "result size mismatch"))
          (let [cmd (bit-and 0xff (aget delta pos))]
            (cond
              (zero? cmd) (damaged "invalid instruction 0")

              (not (zero? (bit-and cmd 0x80)))
              (let [nbytes (+ (Long/bitCount (bit-and cmd 0x0f)) (Long/bitCount (bit-and cmd 0x70)))
                    _ (when (> (+ pos 1 nbytes) dlen) (damaged "truncated copy"))
                    rd (fn [^long k] (bit-and 0xff (aget delta k)))
                    [offset q] (loop [i 0 q (inc pos) v 0]
                                 (if (< i 4)
                                   (if (zero? (bit-and cmd (bit-shift-left 1 i)))
                                     (recur (inc i) q v)
                                     (recur (inc i) (inc q) (bit-or v (bit-shift-left (rd q) (* 8 i)))))
                                   [v q]))
                    [size q] (loop [i 0 q q v 0]
                               (if (< i 3)
                                 (if (zero? (bit-and cmd (bit-shift-left 0x10 i)))
                                   (recur (inc i) q v)
                                   (recur (inc i) (inc q) (bit-or v (bit-shift-left (rd q) (* 8 i)))))
                                 [v q]))
                    size (long (if (zero? size) 0x10000 size))
                    offset (long offset)]
                (when (> (+ offset size) blen) (damaged "copy outside base"))
                (when (> (+ o size) result-size) (damaged "result overflow"))
                (System/arraycopy base (int offset) out (int o) (int size))
                (recur (long q) (+ o size)))

              :else
              (do (when (> (+ pos 1 cmd) dlen) (damaged "truncated insert"))
                  (when (> (+ o cmd) result-size) (damaged "result overflow"))
                  (System/arraycopy delta (int (inc pos)) out (int o) (int cmd))
                  (recur (+ pos 1 cmd) (+ o cmd)))))))
      out)))
