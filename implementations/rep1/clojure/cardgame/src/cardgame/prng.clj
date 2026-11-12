(ns cardgame.prng
  "The 64-bit xorshift* generator of the Spiremark specification.

  Generators are immutable values: [[next-long]] and [[below]] return the new
  generator together with the result.  All arithmetic is on unsigned 64-bit
  integers, carried in Java `long`s."
  )

(def ^:private multiplier 0x2545F4914F6CDD1D)

(defn make
  "A generator seeded with `seed` (an integer in [0, 2^64), given as a
  long holding the same bit pattern, or a BigInt/BigInteger)."
  [seed]
  (let [s (long (if (instance? java.math.BigInteger seed)
                  (.longValue ^java.math.BigInteger seed)
                  (if (integer? seed) (unchecked-long seed) seed)))]
    (if (zero? s) multiplier s)))

(defn next-long
  "Advance generator state `st`.  Returns `[new-state value]`; `value` is the
  unsigned 64-bit output carried in a long."
  [^long st]
  (let [a (bit-xor st (unsigned-bit-shift-right st 12))
        b (bit-xor a (bit-shift-left a 25))
        c (bit-xor b (unsigned-bit-shift-right b 27))]
    [c (unchecked-multiply c multiplier)]))

(defn below
  "A value in [0, n) drawn from `st` (n >= 1).  Returns `[new-state value]`."
  [st n]
  (let [[st' v] (next-long st)]
    [st' (Long/remainderUnsigned (long v) (long n))]))

(defn shuffle-vec
  "Shuffle vector `v` as specified (Fisher-Yates from the end).  Returns
  `[new-state shuffled]`."
  [st v]
  (let [arr (object-array v)
        k   (alength arr)]
    (loop [i (dec k), st st]
      (if (< i 1)
        [st (vec arr)]
        (let [[st' j] (below st (inc i))
              j (int j)
              t (aget arr i)]
          (aset arr i (aget arr j))
          (aset arr j t)
          (recur (dec i) st'))))))
