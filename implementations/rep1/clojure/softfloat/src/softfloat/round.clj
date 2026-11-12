(ns softfloat.round
  "The single shared round-and-pack step.

  Every operation produces a truncated integer result plus a sticky bit; this
  namespace rounds it, once, to nearest-even directly onto the binary32 grid
  (normal or denormal) and packs the bit pattern."
  (:require [softfloat.fields :as f]))

(set! *warn-on-reflection* true)

(defn round-pack
  "Round the value `(m + eps) * 2^e` to binary32 and return its bit pattern.

  * `s`      sign bit (0 or 1) of the result;
  * `m`      positive integer, `m < 2^62`;
  * `e`      exponent of the least significant bit of `m`;
  * `sticky` true when the exact value is strictly greater than `m * 2^e`
             (some nonzero bits were discarded below `m`), i.e. `eps` in
             (0, 1).

  When `sticky` is true, `m` must have at least 26 significant bits so that
  the rounding position is always at least two bits above bit 0.

  Handles gradual underflow (the rounding position is never below 2^-149),
  carry from the rounded significand into the exponent (including the
  denormal-to-normal step) and overflow to infinity."
  ^long [^long s ^long m ^long e sticky]
  (let [n     (f/bit-length m)
        ;; Bits to discard: normal grid keeps 24 bits; the denormal grid
        ;; fixes the lsb weight at 2^-149.
        shift (max (- n 24) (- -149 e))
        ;; Exponent of the leading bit, clamped to the denormal binade.
        lead  (max (+ n e -1) -126)
        q     (cond
                (<= shift 0) (bit-shift-left m (- shift))
                (>= shift 63) 0
                :else
                (let [qq   (bit-shift-right m shift)
                      rmd  (bit-and m (dec (bit-shift-left 1 shift)))
                      half (bit-shift-left 1 (dec shift))]
                  (if (or (> rmd half)
                          (and (== rmd half)
                               (or sticky (odd? qq))))
                    (inc qq)
                    qq)))
        ;; q carries the implicit bit for normal results, so the exponent
        ;; field is added as (biased exponent - 1) = lead + 126; for
        ;; denormals lead is clamped to -126 which gives 0, and q <= 2^23
        ;; spills into 0x00800000 naturally.
        bits  (+ (bit-shift-left (+ lead 126) 23) q)]
    (if (>= bits f/pos-inf)
      (f/pack-inf s)
      (bit-or (bit-shift-left s 31) bits))))
