(ns inflate.huffman
  "Canonical Huffman codes (RFC 1951 section 3.2.2) and two-level lookup tables.

  A table is an `int[]`. The first `2^root` entries are indexed by the next
  `root` stream bits (first bit least significant, i.e. bit-reversed codes).
  An entry is:

    * 0                         - no code starts with these bits;
    * `symbol << 5 | length`    - a leaf: `length` is the full code length;
    * `offset << 5 | 16 | bits` - a link to a second-level table of `2^bits`
                                  entries at `offset`, indexed by the following
                                  `bits` stream bits.

  Building costs O(n_symbols + 2^root); decoding is one or two lookups."
  (:require [inflate.bits :as bits]
            [inflate.error :as err])
  (:import (inflate.bits BitReader)))

(set! *warn-on-reflection* true)

(def ^:const max-code-length 15)

(defn- reverse-bits
  "The low `n` bits of `code` in reverse order."
  ^long [^long code ^long n]
  (unsigned-bit-shift-right (bit-and (Integer/reverse (unchecked-int code)) 0xFFFFFFFF)
                            (- 32 n)))

(defn build
  "Builds a lookup table with `root` root bits for the `n` code lengths
  `lengths[off .. off+n)` (0 = unused symbol, else 1..15).

  The length set must be complete, otherwise a malformed-stream error is
  thrown, except that opts may admit incomplete sets:
    :single-ok? - a lone code of length 1 is accepted;
    :empty-ok?  - a set with no codes at all is accepted.
  Over-subscribed sets are always rejected. Bit patterns matching no code in
  an accepted incomplete table decode to an error."
  [^ints lengths off n root {:keys [single-ok? empty-ok?]}]
  (let [off (long off) n (long n) root (long root)
        count (int-array (inc max-code-length))
        _ (dotimes [i n]
            (let [l (aget lengths (+ off i))]
              (aset count l (inc (aget count l)))))
        used (- n (aget count 0))
        left (loop [l 1, left 1]
               (if (> l max-code-length)
                 left
                 (let [left (- (* 2 left) (aget count l))]
                   (when (neg? left) (err/malformed! "over-subscribed code"))
                   (recur (inc l) left))))]
    (when (pos? left)
      (when-not (or (and empty-ok? (zero? used))
                    (and single-ok? (== used 1) (== 1 (aget count 1))))
        (err/malformed! "incomplete code")))
    (let [next-code (int-array (+ 2 max-code-length))
          _ (aset count 0 0)           ; unused symbols take no part in code assignment
          _ (loop [l 1, code 0]
              (when (<= l max-code-length)
                (let [code (bit-shift-left (+ code (aget count (dec l))) 1)]
                  (aset next-code l code)
                  (recur (inc l) code))))
          root-size (bit-shift-left 1 root)
          root-mask (dec root-size)
          codes (int-array n)
          sub-bits (int-array root-size)]
      ;; Pass 1: assign codes; size the second-level tables.
      (dotimes [i n]
        (let [l (aget lengths (+ off i))]
          (when (pos? l)
            (let [code (aget next-code l)]
              (aset next-code l (inc code))
              (aset codes i code)
              (when (> l root)
                (let [prefix (bit-and (reverse-bits code l) root-mask)]
                  (aset sub-bits prefix (max (aget sub-bits prefix) (- l root)))))))))
      (let [total (loop [p 0, total root-size]
                    (if (< p root-size)
                      (let [sb (aget sub-bits p)]
                        (recur (inc p) (if (pos? sb) (+ total (bit-shift-left 1 sb)) total)))
                      total))
            table (int-array total)]
        ;; Links into the second-level tables.
        (loop [p 0, at root-size]
          (when (< p root-size)
            (let [sb (aget sub-bits p)]
              (if (pos? sb)
                (do (aset table p (bit-or (bit-shift-left at 5) 16 sb))
                    (recur (inc p) (+ at (bit-shift-left 1 sb))))
                (recur (inc p) at)))))
        ;; Pass 2: fill in the leaves.
        (dotimes [i n]
          (let [l (aget lengths (+ off i))]
            (when (pos? l)
              (let [r (reverse-bits (aget codes i) l)
                    leaf (bit-or (bit-shift-left i 5) l)]
                (if (<= l root)
                  (loop [idx r]
                    (when (< idx root-size)
                      (aset table idx leaf)
                      (recur (+ idx (bit-shift-left 1 l)))))
                  (let [link (aget table (bit-and r root-mask))
                        base (unsigned-bit-shift-right link 5)
                        size (bit-shift-left 1 (bit-and link 15))
                        step (bit-shift-left 1 (- l root))]
                    (loop [idx (unsigned-bit-shift-right r root)]
                      (when (< idx size)
                        (aset table (+ base idx) leaf)
                        (recur (+ idx step))))))))))
        table))))

(defn decode
  "Reads one symbol from `br` using `table` (built with root width `root`).
  Throws a malformed-stream error on a bit pattern that is not a code or when
  the stream ends inside the code."
  ^long [^BitReader br ^ints table ^long root]
  (let [window (bits/peek-bits br max-code-length)
        e (aget table (bit-and window (dec (bit-shift-left 1 root))))
        e (if (zero? (bit-and e 16))
            e
            (aget table (+ (unsigned-bit-shift-right e 5)
                           (bit-and (unsigned-bit-shift-right window root)
                                    (dec (bit-shift-left 1 (bit-and e 15)))))))]
    (when (zero? e)
      (err/malformed! "invalid Huffman code"))
    (bits/drop-bits br (bit-and e 15))
    (unsigned-bit-shift-right e 5)))
