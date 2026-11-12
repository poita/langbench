(ns langvm.numfmt
  "Number formatting and parsing (SPEC 14.3, 15.2, 15.3)."
  (:import (java.math BigDecimal BigInteger RoundingMode)))

(set! *warn-on-reflection* true)

(defn show-float-at
  "`showFloatAt`: fixed notation with exactly `d` fraction digits, rounding the
  exact binary value half-to-even."
  ^String [^double x ^long d]
  (cond
    (Double/isNaN x) "nan"
    (Double/isInfinite x) (if (pos? x) "inf" "-inf")
    :else
    (let [neg? (neg? (Double/doubleToRawLongBits x))
          bd (.setScale (BigDecimal. (Math/abs x)) (int d) RoundingMode/HALF_EVEN)
          s (.toPlainString bd)]
      (if neg? (str "-" s) s))))

(defn show-int-radix
  "Digits of `x` in `radix`, the magnitude taken as an unsigned 64-bit value."
  ^String [^long x ^long radix]
  (if (neg? x)
    (str "-" (Long/toUnsignedString (unchecked-negate x) (int radix)))
    (Long/toString x (int radix))))

(defn parse-int-radix
  "Parse `s` (a Java String) as an integer in `radix`; nil when malformed or
  out of range."
  [^String s ^long radix]
  (let [n (.length s)
        start (if (and (pos? n) (let [c (.charAt s 0)] (or (= c \+) (= c \-)))) 1 0)]
    (when (and (< start n)
               (every? (fn [i]
                         (let [d (Character/digit (.charAt s (int i)) (int radix))]
                           (and (>= d 0) (< (int (.charAt s (int i))) 128))))
                       (range start n)))
      (let [v (BigInteger. (if (= (.charAt s 0) \+) (subs s 1) s) (int radix))]
        (when (<= (.bitLength v) 63) (.longValue v))))))

(defn parse-float
  "Parse `s` per SPEC 15.3; nil when the grammar rejects it."
  [^String s]
  (when (re-matches #"[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?" s)
    (Double/parseDouble s)))
