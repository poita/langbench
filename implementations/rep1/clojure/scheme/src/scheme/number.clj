(ns scheme.number
  "Scheme integers: exact, arbitrary precision.

  An integer is a `Long` when it fits in 64 bits and a `Bignum` otherwise;
  every operation returns the normalised form. Long arithmetic is checked for
  overflow and falls back to `scheme.bignum` magnitudes."
  (:refer-clojure :exclude [integer? quot rem])
  (:require [scheme.bignum :as bn])
  (:import [java.lang Math]))

(set! *warn-on-reflection* true)

(deftype Bignum [^long sign ^longs mag]
  Object
  (toString [_]
    (str (when (neg? sign) "-") (bn/mag->string mag))))

(defn integer? "True for a Long or Bignum." [x]
  (or (instance? Long x) (instance? Bignum x)))

(defn- norm
  "The normalised integer with the given sign (-1/1) and magnitude."
  [^long sign ^longs mag]
  (let [n (alength mag)]
    (if (zero? n)
      0
      (let [l2 (if (== n 3) (aget mag 2) 0)]
        (if (or (> n 3) (> l2 3))
          (Bignum. sign mag)
          (let [u (bit-or (aget mag 0)
                          (if (> n 1) (bit-shift-left (aget mag 1) 31) 0)
                          (bit-shift-left l2 62))] ; unsigned 64-bit value
            (cond
              (>= u 0) (if (neg? sign) (- u) u)
              (and (== u Long/MIN_VALUE) (neg? sign)) u
              :else (Bignum. sign mag))))))))

(defn- ->big ^Bignum [x]
  (if (instance? Bignum x)
    x
    (let [l (long x)]
      (Bignum. (if (neg? l) -1 1) (bn/long->mag l)))))

(defn zero-int? [x] (and (instance? Long x) (zero? (long x))))

(defn negate [x]
  (if (instance? Long x)
    (let [l (long x)]
      (if (== l Long/MIN_VALUE)
        (Bignum. 1 (bn/long->mag l))
        (- l)))
    (let [^Bignum b x]
      (norm (- (.sign b)) (.mag b)))))

(defn- add-big [a b]
  (let [^Bignum x (->big a) ^Bignum y (->big b)]
    (if (== (.sign x) (.sign y))
      (norm (.sign x) (bn/mag-add (.mag x) (.mag y)))
      (let [c (bn/mag-cmp (.mag x) (.mag y))]
        (cond
          (zero? c) 0
          (pos? c) (norm (.sign x) (bn/mag-sub (.mag x) (.mag y)))
          :else (norm (.sign y) (bn/mag-sub (.mag y) (.mag x))))))))

(defn add [a b]
  (if (and (instance? Long a) (instance? Long b))
    (let [x (long a) y (long b) r (unchecked-add x y)]
      (if (neg? (bit-and (bit-xor x r) (bit-xor y r)))
        (add-big a b)
        r))
    (add-big a b)))

(defn sub [a b]
  (if (and (instance? Long a) (instance? Long b))
    (let [x (long a) y (long b) r (unchecked-subtract x y)]
      (if (neg? (bit-and (bit-xor x y) (bit-xor x r)))
        (add-big a (negate b))
        r))
    (add-big a (negate b))))

(defn mul [a b]
  (if (and (instance? Long a) (instance? Long b))
    (let [x (long a) y (long b)
          hi (Math/multiplyHigh x y)
          lo (unchecked-multiply x y)]
      (if (or (and (zero? hi) (>= lo 0)) (and (== hi -1) (neg? lo)))
        lo
        (let [^Bignum p (->big a) ^Bignum q (->big b)]
          (norm (* (.sign p) (.sign q)) (bn/mag-mul (.mag p) (.mag q))))))
    (let [^Bignum p (->big a) ^Bignum q (->big b)]
      (norm (* (.sign p) (.sign q)) (bn/mag-mul (.mag p) (.mag q))))))

(defn- divmod-big [a b]
  (let [^Bignum x (->big a) ^Bignum y (->big b)
        [q r] (bn/mag-divmod (.mag x) (.mag y))]
    [(norm (* (.sign x) (.sign y)) q) (norm (.sign x) r)]))

(defn quot
  "Integer division truncating toward zero; `b` must be non-zero."
  [a b]
  (if (and (instance? Long a) (instance? Long b))
    (let [y (long b)]
      (if (== y -1) (negate a) (clojure.core/quot (long a) y)))
    (first (divmod-big a b))))

(defn rem
  "Remainder with the sign of `a`; `b` must be non-zero."
  [a b]
  (if (and (instance? Long a) (instance? Long b))
    (let [y (long b)]
      (if (== y -1) 0 (clojure.core/rem (long a) y)))
    (second (divmod-big a b))))

(defn compare-int
  "-1, 0 or 1 as `a` is less than, equal to or greater than `b`."
  ^long [a b]
  (if (and (instance? Long a) (instance? Long b))
    (Long/compare (long a) (long b))
    (let [^Bignum x (->big a) ^Bignum y (->big b)
          zx (zero? (alength (.mag x))) zy (zero? (alength (.mag y)))
          sx (if zx 0 (.sign x)) sy (if zy 0 (.sign y))]
      (cond
        (< sx sy) -1
        (> sx sy) 1
        (zero? sx) 0
        :else (* sx (bn/mag-cmp (.mag x) (.mag y)))))))

(defn parse-integer
  "Parse an optionally signed string of ASCII digits."
  [^String s]
  (let [neg? (= (.charAt s 0) \-)
        start (if (contains? #{\+ \-} (.charAt s 0)) 1 0)
        digits (.substring s start)]
    (if (<= (.length digits) 18)
      (let [v (Long/parseLong digits)] (if neg? (- v) v))
      (norm (if neg? -1 1) (bn/digits->mag digits)))))

(defn ->string
  "Decimal representation of an integer."
  ^String [x]
  (.toString ^Object x))
