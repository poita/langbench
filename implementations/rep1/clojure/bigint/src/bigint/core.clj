(ns bigint.core
  "Arbitrary-precision signed integers, implemented from scratch.

  A value is a `BigInt` (sign + base-10^9 magnitude). All operations are the
  classical ones: linear add/subtract/compare, schoolbook multiplication,
  Knuth Algorithm D division and binary exponentiation. Decimal parsing and
  printing are linear.

      (require '[bigint.core :as bi])
      (-> (bi/parse \"-123456789012345678901234567890\")
          (bi/mul (bi/parse \"987654321098765432109876543210\"))
          bi/->string)
      ;=> \"-121932631137021795226185032733622923332237463801111263526900\"

  Values are immutable. Zero is canonical: it has sign 0 and is never
  negative, so `-0` cannot exist."
  (:refer-clojure :exclude [compare zero? neg? pos? abs rem quot])
  (:require [bigint.decimal :as dec]
            [bigint.magnitude :as mag]))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(deftype BigInt [^long sign ^longs mag]
  Object
  (toString [_]
    (let [sb (StringBuilder.)]
      (when (< sign 0) (.append sb \-))
      (str (dec/append-magnitude sb mag))))
  (equals [_ o]
    (and (instance? BigInt o)
         (let [^BigInt o o]
           (and (== sign (.-sign o)) (java.util.Arrays/equals mag ^longs (.-mag o))))))
  (hashCode [_]
    (+ (* 31 (java.util.Arrays/hashCode mag)) sign))
  Comparable
  (compareTo [_ o]
    (let [^BigInt o o
          so (.-sign o)]
      (cond
        (< sign so) -1
        (> sign so) 1
        (== sign 0) 0
        (> sign 0) (mag/compare mag (.-mag o))
        :else (mag/compare (.-mag o) mag)))))

(defmethod print-method BigInt [x ^java.io.Writer w]
  (.write w "#bigint/str \"")
  (.write w (.toString ^Object x))
  (.write w "\""))

(defn- make
  "Builds a BigInt from a sign and a normalised magnitude, canonicalising
  zero."
  [^long sign ^longs mag]
  (if (mag/zero? mag) (->BigInt 0 mag) (->BigInt sign mag)))

(defn bigint?
  "True if `x` is a `bigint.core/BigInt`."
  [x]
  (instance? BigInt x))

(def zero "The value 0." (->BigInt 0 mag/zero))
(def one "The value 1." (make 1 (mag/from-long 1)))

(defn signum
  "-1, 0 or 1 according to the sign of `x`."
  ^long [^BigInt x]
  (.-sign x))

(defn zero? "True if `x` is zero." [x] (== 0 (signum x)))
(defn neg? "True if `x` is negative." [x] (< (signum x) 0))
(defn pos? "True if `x` is positive." [x] (> (signum x) 0))

(defn parse
  "Parses a string matching `-?[0-9]+` (leading zeros and `-0` allowed).
  Throws `ex-info` with `:type :bigint.core/parse-error` on anything else."
  [^String s]
  (let [n (.length s)
        neg (and (> n 0) (== (int \-) (int (.charAt s 0))))
        start (if neg 1 0)]
    (when (== start n)
      (throw (ex-info "Empty number" {:type ::parse-error :input s})))
    (try
      (make (if neg -1 1) (dec/parse-digits s start n))
      (catch clojure.lang.ExceptionInfo e
        (throw (ex-info "Malformed integer" {:type ::parse-error :input s} e))))))

(defn of-long
  "The BigInt equal to the machine integer `n`."
  [^long n]
  (if (== n Long/MIN_VALUE)
    (parse (Long/toString n))
    (make (if (< n 0) -1 1) (mag/from-long (Math/abs n)))))

(defn ->string
  "Canonical decimal string of `x`: no leading zeros, `-` only when negative."
  ^String [^BigInt x]
  (.toString x))

(defn ->long
  "The value of `x` as a long, or nil if it is outside the range that fits in
  two limbs (|x| < 10^18)."
  [^BigInt x]
  (when-let [m (mag/to-long (.-mag x))]
    (* (.-sign x) (long m))))

(defn compare
  "Three-way numeric comparison: -1, 0 or 1."
  ^long [^BigInt a ^BigInt b]
  (let [c (.compareTo a b)] (long c)))

(defn negate
  "-x."
  [^BigInt x]
  (->BigInt (- (.-sign x)) (.-mag x)))

(defn abs
  "|x|."
  [^BigInt x]
  (if (< (.-sign x) 0) (negate x) x))

(defn add
  "a + b."
  [^BigInt a ^BigInt b]
  (let [sa (.-sign a) sb (.-sign b)]
    (cond
      (== sa 0) b
      (== sb 0) a
      (== sa sb) (->BigInt sa (mag/add (.-mag a) (.-mag b)))
      :else (let [c (mag/compare (.-mag a) (.-mag b))]
              (cond
                (== c 0) zero
                (> c 0) (->BigInt sa (mag/sub (.-mag a) (.-mag b)))
                :else (->BigInt sb (mag/sub (.-mag b) (.-mag a))))))))

(defn sub
  "a - b."
  [a b]
  (add a (negate b)))

(defn mul
  "a * b (schoolbook, O(n*m))."
  [^BigInt a ^BigInt b]
  (make (* (.-sign a) (.-sign b)) (mag/mul (.-mag a) (.-mag b))))

(defn quot-rem
  "Truncating division. Returns [q r] with a = q*b + r, |r| < |b| and r zero
  or of the same sign as a. Throws `ArithmeticException` if b is zero."
  [^BigInt a ^BigInt b]
  (when (== 0 (.-sign b))
    (throw (ArithmeticException. "Divide by zero")))
  (let [[q r] (mag/quot-rem (.-mag a) (.-mag b))]
    [(make (* (.-sign a) (.-sign b)) q)
     (make (.-sign a) r)]))

(defn quot
  "Quotient of a / b truncated toward zero. Throws on zero divisor."
  [a b]
  (nth (quot-rem a b) 0))

(defn rem
  "Remainder of a / b, with the sign of a. Throws on zero divisor."
  [a b]
  (nth (quot-rem a b) 1))

(defn pow
  "a raised to the power `e`, where `e` is a BigInt or a long and must be
  non-negative (`0^0` is 1). Throws `IllegalArgumentException` for a negative
  exponent, and for an exponent too large to compute unless the base is 0,
  1 or -1."
  [^BigInt a e]
  (let [^BigInt e (if (bigint? e) e (of-long e))]
    (when (neg? e)
      (throw (IllegalArgumentException. "Negative exponent")))
    (let [^longs ml (.-mag e)
          ^longs am (.-mag a)
          odd? (and (> (alength ml) 0) (odd? (aget ml 0)))
          sa (.-sign a)]
      (cond
        (zero? e) one
        (== sa 0) zero
        (and (== 1 (alength am)) (== 1 (aget am 0)))
        (if (and (< sa 0) odd?) (negate one) one)
        :else
        (let [n (mag/to-long ml)]
          (when-not n
            (throw (IllegalArgumentException. "Exponent too large")))
          (make (if (and (< sa 0) odd?) -1 1) (mag/pow am (long n))))))))
