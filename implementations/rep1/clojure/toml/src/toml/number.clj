(ns toml.number
  "Integers, floats and booleans: validation of their TOML syntax and the
  canonical text forms used in tagged trees."
  (:require [toml.data :as d])
  (:import (java.math BigDecimal MathContext RoundingMode)))

(set! *warn-on-reflection* true)

(defn- code
  "The code unit at `i`, or -1 past the end."
  ^long [^String s ^long i]
  (if (< i (.length s)) (long (int (.charAt s i))) -1))

(defn- digit-value
  "Value of an ASCII hexadecimal digit, or -1."
  ^long [^long c]
  (cond (and (>= c 48) (<= c 57)) (- c 48)
        (and (>= c 97) (<= c 102)) (- c 87)
        (and (>= c 65) (<= c 70)) (- c 55)
        :else -1))

(defn- digit-in-radix? [^long c ^long radix]
  (let [v (digit-value c)]
    (and (>= v 0) (< v radix))))

(defn- scan-digits
  "Scans `digit ('_'? digit)*` in `radix` from `i`; returns the end index, or
  -1 when there is no digit at `i`."
  ^long [^String t ^long i ^long radix]
  (loop [j i prev? false]
    (let [c (code t j)]
      (cond (digit-in-radix? c radix) (recur (unchecked-inc j) true)
            (and prev? (== c 95) (digit-in-radix? (code t (unchecked-inc j)) radix))
            (recur (unchecked-inc j) false)
            :else (if prev? j -1)))))

(defn format-float
  "Formats a double exactly like C's `%.16e`: 17 significant digits, an
  explicit exponent sign and at least two exponent digits.  NaN prints as
  `nan` and the infinities as `inf` / `-inf`."
  [^double x]
  (cond
    (Double/isNaN x) "nan"
    (Double/isInfinite x) (if (pos? x) "inf" "-inf")
    :else
    (let [negative? (neg? (Double/doubleToRawLongBits x))
          sign (if negative? "-" "")]
      (if (zero? x)
        (str sign "0.0000000000000000e+00")
        (let [bd     (.round (BigDecimal. (Math/abs x)) (MathContext. 17 RoundingMode/HALF_EVEN))
              digits (str (.unscaledValue bd))
              exp    (- (.precision bd) (.scale bd) 1)
              digits (str digits (apply str (repeat (- 17 (count digits)) \0)))]
          (str sign (subs digits 0 1) "." (subs digits 1)
               "e" (if (neg? exp) "-" "+")
               (let [e (Math/abs (long exp))] (if (< e 10) (str "0" e) (str e)))))))))

(defn parse-float-text
  "Converts canonical float text (as produced by [[format-float]]) to a double."
  ^double [^String text]
  (case text
    "nan" Double/NaN
    "inf" Double/POSITIVE_INFINITY
    "-inf" Double/NEGATIVE_INFINITY
    (Double/parseDouble text)))

(defn- strip-underscores ^String [^String t] (.replace t "_" ""))

(defn- parse-radix-int [^String t ^long radix]
  (let [end (scan-digits t 2 radix)]
    (when (== end (.length t))
      (try (d/scalar :integer (Long/toString (Long/parseLong (strip-underscores (subs t 2)) radix)))
           (catch NumberFormatException _ nil)))))

(defn- parse-decimal [^String t ^long i]
  (let [n (.length t)
        j (scan-digits t i 10)]
    (when (and (>= j 0)
               (not (and (== (code t i) 48) (> j (inc i)))))   ; leading zero
      (if (== j n)
        (try (d/scalar :integer (Long/toString (Long/parseLong (strip-underscores t))))
             (catch NumberFormatException _ nil))
        (let [k (if (== (code t j) 46) (scan-digits t (inc j) 10) j)
              k (if (and (>= k 0) (let [c (code t k)] (or (== c 101) (== c 69))))
                  (let [m (inc k)
                        m (if (let [c (code t m)] (or (== c 43) (== c 45))) (inc m) m)]
                    (scan-digits t m 10))
                  k)]
          (when (and (== k n) (> k j))
            (d/scalar :float (format-float (Double/parseDouble (strip-underscores t))))))))))

(defn parse-number
  "Parses the text of a bare number token (integer or float, any base, with
  optional sign, `inf`, `nan`).  Returns a scalar, or nil when the text is not
  a valid TOML number or an integer does not fit in 64 bits."
  [^String t]
  (let [c0      (code t 0)
        signed? (or (== c0 43) (== c0 45))
        i       (if signed? 1 0)
        rest    (subs t i)]
    (cond
      (= rest "inf") (d/scalar :float (if (== c0 45) "-inf" "inf"))
      (= rest "nan") (d/scalar :float "nan")
      (and (not signed?) (== c0 48) (let [c (code t 1)] (or (== c 120) (== c 111) (== c 98))))
      (parse-radix-int t (case (int (code t 1)) 120 16, 111 8, 98 2))
      :else (parse-decimal t i))))
