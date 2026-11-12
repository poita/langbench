(ns softfloat.div
  "binary32 division."
  (:require [softfloat.fields :as f]
            [softfloat.round :as r]))

(set! *warn-on-reflection* true)

(defn div
  "Quotient `a / b` of binary32 patterns, as a pattern."
  ^long [^long a ^long b]
  (let [s (bit-xor (f/sign a) (f/sign b))]
    (cond
      (or (f/nan? a) (f/nan? b)) f/quiet-nan

      (f/infinite? a) (if (f/infinite? b) f/quiet-nan (f/pack-inf s))
      (f/infinite? b) (f/pack-zero s)

      (f/zero? b) (if (f/zero? a) f/quiet-nan (f/pack-inf s))
      (f/zero? a) (f/pack-zero s)

      :else
      ;; Normalised 24-bit significands give a quotient ma/mb in (1/2, 2);
      ;; scaling the dividend by 2^26 yields a quotient of 26 or 27 bits.
      (let [[^long ma ^long ea] (f/unpack-normalized a)
            [^long mb ^long eb] (f/unpack-normalized b)
            num (bit-shift-left ma 26)
            q   (quot num mb)
            rmd (rem num mb)]
        (r/round-pack s q (- ea eb 26) (not (zero? rmd)))))))
