(ns bigint.core
  "Signed arbitrary-precision integers.

  An `Int` is a sign and a magnitude held in base 10^9 (see `bigint.mag`).
  Values are immutable and always canonical: zero has sign 0 and an empty
  magnitude, so there is no negative zero and `=`, `hash` and `compare` agree
  with numeric equality.

  Typical use:

      (require '[bigint.core :as bi])
      (bi/->string (bi/mul (bi/parse \"-12345678901234567890\") (bi/parse \"98765\")))

  Operations that cannot be defined throw `ex-info` whose `:type` is
  `::division-by-zero` or `::negative-exponent`."
  (:refer-clojure :exclude [zero? neg? pos? abs quot rem])
  (:require [bigint.mag :as mag])
  (:import (java.util Arrays)))

(set! *warn-on-reflection* true)

(declare ->string)

(deftype Int [^long sign ^longs mag]
  Object
  (toString [this] (->string this))
  (equals [_ other]
    (and (instance? Int other)
         (== sign (.-sign ^Int other))
         (== 0 (mag/cmp mag (.-mag ^Int other)))))
  (hashCode [_]
    (unchecked-add-int (unchecked-multiply-int 31 (int sign))
                       (Arrays/hashCode mag)))
  Comparable
  (compareTo [_ other]
    (let [^Int o other
          s2 (.-sign o)]
      (cond
        (< sign s2) -1
        (> sign s2) 1
        (== sign 0) 0
        (== sign 1) (int (mag/cmp mag (.-mag o)))
        :else (int (mag/cmp (.-mag o) mag))))))

(defn- make
  "Build a canonical Int from a sign (-1, 1; ignored for zero) and a
  normalised magnitude."
  ^Int [^long sign ^longs m]
  (if (mag/zero-mag? m)
    (Int. 0 mag/zero)
    (Int. sign m)))

(def ^Int zero "The integer 0." (make 0 mag/zero))
(def ^Int one "The integer 1." (make 1 (mag/from-long 1)))

(defn int-value?
  "True when `x` is an `Int`."
  [x]
  (instance? Int x))

;; ---------------------------------------------------------------- conversion

(defn from-long
  "Convert a Clojure long to an Int."
  ^Int [^long x]
  (make (if (< x 0) -1 1) (mag/from-long x)))

(defn parse
  "Parse a decimal integer matching `-?[0-9]+`. Leading zeros and `-0` forms
  are accepted (and normalised). Throws ex-info with `:type ::parse-error`
  for anything else. Linear time."
  ^Int [^String s]
  (let [len (.length s)
        neg (and (> len 0) (== (int (.charAt s 0)) 45))
        st  (if neg 1 0)]
    (when (== st len)
      (throw (ex-info "Not a decimal integer" {:type ::parse-error :input s})))
    (let [m (try (mag/parse s st len)
                 (catch clojure.lang.ExceptionInfo e
                   (throw (ex-info "Not a decimal integer"
                                   {:type ::parse-error :input s} e))))]
      (make (if neg -1 1) m))))

(defn ->string
  "Canonical decimal form: no leading zeros, `-` only for negative values."
  ^String [^Int x]
  (if (== (.-sign x) -1)
    (str "-" (mag/->digits (.-mag x)))
    (mag/->digits (.-mag x))))

;; ---------------------------------------------------------------- predicates

(defn signum
  "-1, 0 or 1 according to the sign of `x`."
  ^long [^Int x]
  (.-sign x))

(defn zero? "True when `x` is zero." [^Int x] (== 0 (.-sign x)))
(defn neg?  "True when `x` is negative." [^Int x] (== -1 (.-sign x)))
(defn pos?  "True when `x` is positive." [^Int x] (== 1 (.-sign x)))

(defn cmp
  "Three-way numeric comparison: -1, 0 or 1."
  ^long [^Int a ^Int b]
  (long (.compareTo a b)))

;; ---------------------------------------------------------------- arithmetic

(defn negate "-x." ^Int [^Int x] (make (- (.-sign x)) (.-mag x)))

(defn abs "|x|." ^Int [^Int x] (make 1 (.-mag x)))

(defn add
  "a + b."
  ^Int [^Int a ^Int b]
  (let [sa (.-sign a), sb (.-sign b)
        ma (.-mag a), mb (.-mag b)]
    (cond
      (== sa 0) b
      (== sb 0) a
      (== sa sb) (make sa (mag/add ma mb))
      :else (let [c (mag/cmp ma mb)]
              (cond
                (== c 0) zero
                (> c 0)  (make sa (mag/sub ma mb))
                :else    (make sb (mag/sub mb ma)))))))

(defn sub
  "a - b."
  ^Int [^Int a ^Int b]
  (add a (negate b)))

(defn mul
  "a * b, by schoolbook multiplication."
  ^Int [^Int a ^Int b]
  (make (* (.-sign a) (.-sign b)) (mag/mul (.-mag a) (.-mag b))))

(defn quot-rem
  "Truncating division. Returns [quotient remainder] such that
  a = q*b + r, |r| < |b|, and r is zero or has the sign of a (C semantics).
  Throws ex-info with `:type ::division-by-zero` when b is zero."
  [^Int a ^Int b]
  (when (clojure.core/zero? (.-sign b))
    (throw (ex-info "Division by zero" {:type ::division-by-zero})))
  (let [[q r] (mag/divmod (.-mag a) (.-mag b))]
    [(make (* (.-sign a) (.-sign b)) q)
     (make (.-sign a) r)]))

(defn quot
  "Quotient of `a` / `b`, truncated toward zero."
  ^Int [^Int a ^Int b]
  (first (quot-rem a b)))

(defn rem
  "Remainder of `a` / `b`, with the sign of `a`."
  ^Int [^Int a ^Int b]
  (second (quot-rem a b)))

(defn- small-exponent
  "The magnitude `m` as a long. Only called when it matters, i.e. for bases
  other than 0, 1 and -1, where larger exponents cannot be computed anyway."
  ^long [^longs m]
  (if (<= (alength m) 2)
    (+ (* (if (== (alength m) 2) (aget m 1) 0) mag/base)
       (if (> (alength m) 0) (aget m 0) 0))
    (throw (ex-info "Exponent too large" {:type ::exponent-too-large}))))

(defn pow
  "a raised to the power `b` by binary exponentiation. `0^0` is 1. Throws
  ex-info with `:type ::negative-exponent` when b is negative."
  ^Int [^Int a ^Int b]
  (let [sa (.-sign a), mb (.-mag b)]
    (cond
      (== (.-sign b) -1) (throw (ex-info "Negative exponent"
                                         {:type ::negative-exponent}))
      (== (.-sign b) 0)  one
      (== sa 0)          zero
      (== 0 (mag/cmp (.-mag a) (.-mag one)))   ; a is 1 or -1
      (if (and (== sa -1) (not (mag/even-mag? mb))) a one)
      :else
      (let [e (small-exponent mb)]
        (make (if (and (== sa -1) (odd? e)) -1 1)
              (mag/pow (.-mag a) e))))))
