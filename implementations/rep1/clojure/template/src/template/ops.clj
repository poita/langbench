(ns template.ops
  "The binary and unary operators of the expression language.

  Every function takes already-evaluated operands. An undefined operand is an
  `undefined` error; operands of the wrong kind are a `type` error."
  (:require [template.errors :as err]
            [template.values :as v :refer [undefined?]])
  (:import (java.util LinkedHashMap)))

(set! *warn-on-reflection* true)

(defn- no-undefined [a b]
  (when (or (undefined? a) (undefined? b))
    (err/fail :undefined "operator applied to an undefined value")))

(defn- type-error [what] (err/fail :type what))

(defn- both-long? [a b] (and (instance? Long a) (instance? Long b)))

(defn add [a b]
  (no-undefined a b)
  (cond
    (and (v/number-value? a) (v/number-value? b))
    (let [a (v/->num a) b (v/->num b)]
      (if (both-long? a b)
        (unchecked-add (long a) (long b))
        (+ (double a) (double b))))
    (and (string? a) (string? b)) (.concat ^String a ^String b)
    (and (vector? a) (vector? b)) (into a b)
    :else (type-error "unsupported operands for +")))

(defn sub [a b]
  (no-undefined a b)
  (if (and (v/number-value? a) (v/number-value? b))
    (let [a (v/->num a) b (v/->num b)]
      (if (both-long? a b)
        (unchecked-subtract (long a) (long b))
        (- (double a) (double b))))
    (type-error "unsupported operands for -")))

(defn neg [a]
  (cond
    (undefined? a) (err/fail :undefined "negation of an undefined value")
    (v/number-value? a) (let [a (v/->num a)]
                          (if (instance? Long a) (unchecked-negate (long a)) (- (double a))))
    :else (type-error "bad operand for unary -")))

(defn- repeat-string [^String s ^long n]
  (if (<= n 0)
    ""
    (let [sb (StringBuilder. (* (.length s) (int (min n 1000000))))]
      (dotimes [_ n] (.append sb s))
      (.toString sb))))

(defn mul [a b]
  (no-undefined a b)
  (cond
    (and (v/number-value? a) (v/number-value? b))
    (let [a (v/->num a) b (v/->num b)]
      (if (both-long? a b)
        (unchecked-multiply (long a) (long b))
        (* (double a) (double b))))
    (and (string? a) (v/int-like? b)) (repeat-string a (long (v/->num b)))
    (and (v/int-like? a) (string? b)) (repeat-string b (long (v/->num a)))
    :else (type-error "unsupported operands for *")))

(defn- zero-divisor? [b]
  (if (instance? Long b) (zero? (long b)) (zero? (double b))))

(defn- numeric-operands [a b op]
  (no-undefined a b)
  (when-not (and (v/number-value? a) (v/number-value? b))
    (type-error (str "unsupported operands for " op)))
  (let [a (v/->num a) b (v/->num b)]
    (when (zero-divisor? b) (type-error "division or modulo by zero"))
    [a b]))

(defn div [a b]
  (let [[a b] (numeric-operands a b "/")]
    (/ (double a) (double b))))

(defn- float-mod ^double [^double a ^double b]
  (let [m (rem a b)]
    (if (zero? m)
      (Math/copySign 0.0 b)
      (if (not= (neg? b) (neg? m)) (+ m b) m))))

(defn- float-floordiv ^double [^double a ^double b]
  (let [m   (rem a b)
        div (/ (- a m) b)
        div (if (and (not (zero? m)) (not= (neg? b) (neg? m))) (- div 1.0) div)]
    (if (zero? div)
      (Math/copySign 0.0 (/ a b))
      (let [fl (Math/floor div)]
        (if (> (- div fl) 0.5) (+ fl 1.0) fl)))))

(defn floordiv [a b]
  (let [[a b] (numeric-operands a b "//")]
    (if (both-long? a b)
      (Math/floorDiv (long a) (long b))
      (float-floordiv (double a) (double b)))))

(defn modulo [a b]
  (let [[a b] (numeric-operands a b "%")]
    (if (both-long? a b)
      (Math/floorMod (long a) (long b))
      (float-mod (double a) (double b)))))

(defn- int-pow ^long [^long base ^long exp]
  (loop [result 1 base base exp exp]
    (cond
      (zero? exp) result
      (odd? exp) (recur (unchecked-multiply result base) (unchecked-multiply base base) (quot exp 2))
      :else (recur result (unchecked-multiply base base) (quot exp 2)))))

(defn power [a b]
  (no-undefined a b)
  (when-not (and (v/number-value? a) (v/number-value? b))
    (type-error "unsupported operands for **"))
  (let [a (v/->num a) b (v/->num b)]
    (cond
      (and (both-long? a b) (>= (long b) 0)) (int-pow (long a) (long b))
      (zero? (double a)) (if (neg? (double b))
                           (type-error "zero to a negative power")
                           (Math/pow (double a) (double b)))
      :else (Math/pow (double a) (double b)))))

(defn concat-str [a b]
  (str (v/to-str a) (v/to-str b)))

;; ---------------------------------------------------------------------------
;; Comparison

(defn equal? [a b] (v/values-equal? a b))

(defn compare-op
  "`<`, `<=`, `>` or `>=` (op is :lt :le :gt :ge)."
  [op a b]
  (no-undefined a b)
  (let [c (cond
            (and (v/number-value? a) (v/number-value? b)) (v/compare-numbers a b)
            (and (string? a) (string? b)) (v/compare-strings a b)
            :else (type-error "values are not ordered"))]
    (case op
      :lt (neg? c)
      :le (not (pos? c))
      :gt (pos? c)
      :ge (not (neg? c)))))

(defn member?
  "`a in b`."
  [a b]
  (no-undefined a b)
  (cond
    (string? b) (if (string? a)
                  (>= (.indexOf ^String b ^String a) 0)
                  (type-error "'in <string>' requires a string as left operand"))
    (v/dict? b) (and (string? a) (.containsKey ^LinkedHashMap b a))
    (vector? b) (boolean (some #(v/values-equal? a %) b))
    :else (type-error "argument of type is not iterable")))

(defn binary
  "Apply arithmetic/concatenation operator `op` (a keyword) to `a` and `b`."
  [op a b]
  (case op
    :add (add a b)
    :sub (sub a b)
    :mul (mul a b)
    :div (div a b)
    :floordiv (floordiv a b)
    :mod (modulo a b)
    :pow (power a b)
    :concat (concat-str a b)))

(defn compare-chain-op
  "Apply one comparison operator of a chain (:eq :ne :lt :le :gt :ge :in :not-in)."
  [op a b]
  (case op
    :eq (equal? a b)
    :ne (not (equal? a b))
    :in (member? a b)
    :not-in (not (member? a b))
    (compare-op op a b)))
