(ns softfloat.fields
  "Bit-field layout of IEEE-754 binary32 values.

  A binary32 value is exchanged as a Clojure `long` holding the raw 32-bit
  pattern (0 .. 0xFFFFFFFF).  This namespace splits patterns into sign,
  exponent and fraction, classifies them, and unpacks finite values into an
  integer significand and exponent.  Nothing here uses floating point."
  (:refer-clojure :exclude [infinite? nan? zero?]))

(set! *warn-on-reflection* true)

(def ^:const quiet-nan
  "The canonical quiet NaN, the only NaN this library ever returns."
  0x7fc00000)

(def ^:const pos-inf 0x7f800000)
(def ^:const sign-mask 0x80000000)

(defn sign
  "Sign bit of pattern `x`: 0 or 1."
  ^long [^long x]
  (bit-and (bit-shift-right x 31) 1))

(defn exponent-field
  "Biased 8-bit exponent field of `x`."
  ^long [^long x]
  (bit-and (bit-shift-right x 23) 0xff))

(defn fraction
  "23-bit fraction field of `x`."
  ^long [^long x]
  (bit-and x 0x7fffff))

(defn nan?
  "True when `x` is a NaN of any sign, payload or quietness."
  [^long x]
  (> (bit-and x 0x7fffffff) 0x7f800000))

(defn infinite?
  "True when `x` is +/- infinity."
  [^long x]
  (= (bit-and x 0x7fffffff) 0x7f800000))

(defn zero?
  "True when `x` is +0 or -0."
  [^long x]
  (== 0 (bit-and x 0x7fffffff)))

(defn negate
  "`x` with its sign bit flipped."
  ^long [^long x]
  (bit-xor x sign-mask))

(defn pack-inf
  "Infinity with sign bit `s`."
  ^long [^long s]
  (bit-or (bit-shift-left s 31) pos-inf))

(defn pack-zero
  "Zero with sign bit `s`."
  ^long [^long s]
  (bit-shift-left s 31))

(defn unpack
  "Unpack a finite, nonzero pattern into `[m e]` such that |x| = m * 2^e.
  `m` is the integer significand (with the implicit bit for normal numbers,
  not normalised for denormals)."
  [^long x]
  (let [ef (exponent-field x)
        f  (fraction x)]
    (if (== 0 ef)
      [f -149]
      [(bit-or f 0x800000) (- ef 150)])))

(defn bit-length
  "Number of significant bits of the non-negative long `n` (0 for 0)."
  ^long [^long n]
  (- 64 (Long/numberOfLeadingZeros n)))

(defn unpack-normalized
  "Like [[unpack]] but the significand is shifted left until it occupies
  exactly 24 bits (bit 23 set), the exponent being decreased to match."
  [^long x]
  (let [[^long m ^long e] (unpack x)
        s (- 24 (bit-length m))]
    [(bit-shift-left m s) (- e s)]))
