(ns softfloat.mul
  "binary32 multiplication."
  (:require [softfloat.fields :as f]
            [softfloat.round :as r]))

(set! *warn-on-reflection* true)

(defn mul
  "Product of binary32 patterns `a` and `b`, as a pattern."
  ^long [^long a ^long b]
  (let [s (bit-xor (f/sign a) (f/sign b))]
    (cond
      (or (f/nan? a) (f/nan? b)) f/quiet-nan

      (f/infinite? a) (if (f/zero? b) f/quiet-nan (f/pack-inf s))
      (f/infinite? b) (if (f/zero? a) f/quiet-nan (f/pack-inf s))

      (or (f/zero? a) (f/zero? b)) (f/pack-zero s)

      :else
      (let [[^long ma ^long ea] (f/unpack a)
            [^long mb ^long eb] (f/unpack b)]
        ;; Exact product of two <=24-bit significands: at most 48 bits.
        (r/round-pack s (* ma mb) (+ ea eb) false)))))
