(ns softfloat.sqrt
  "binary32 square root."
  (:require [softfloat.fields :as f]
            [softfloat.round :as r]))

(set! *warn-on-reflection* true)

(defn isqrt-rem
  "Restoring digit-by-digit integer square root of `n` (0 <= n < 2^62).
  Returns `[root remainder]` with `root^2 + remainder = n`.  One result bit
  is produced per step, at most 31 steps."
  [^long n]
  (loop [num n
         res 0
         bit (bit-shift-left 1 60)]
    ;; Start from the highest power of four not above n.
    (if (> bit num)
      (recur num res (bit-shift-right bit 2))
      (loop [num num res res bit bit]
        (if (zero? bit)
          [res num]
          (let [t (+ res bit)]
            (if (>= num t)
              (recur (- num t) (+ (bit-shift-right res 1) bit) (bit-shift-right bit 2))
              (recur num (bit-shift-right res 1) (bit-shift-right bit 2)))))))))

(defn sqrt
  "Square root of binary32 pattern `a`, as a pattern."
  ^long [^long a]
  (cond
    (f/nan? a) f/quiet-nan
    (f/zero? a) a
    (== (f/sign a) 1) f/quiet-nan
    (f/infinite? a) a

    :else
    (let [[^long m ^long e] (f/unpack-normalized a)
          ;; Make the exponent even: value = m * 2^e with e even.
          odd (odd? e)
          m    (if odd (bit-shift-left m 1) m)
          e    (if odd (dec e) e)
          ;; m < 2^25; m * 2^28 < 2^53 has a root of 26 or 27 bits.
          [^long root ^long rmd] (isqrt-rem (bit-shift-left m 28))]
      (r/round-pack 0 root (bit-shift-right (- e 28) 1) (not (zero? rmd))))))
