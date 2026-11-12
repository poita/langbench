(ns jq.ops
  "Binary arithmetic and comparison operators, and unary negation."
  (:require [jq.error :as err]
            [jq.value :as v])
  (:import (java.util LinkedHashMap Map$Entry)))

(set! *warn-on-reflection* true)

(defn- type-fail [op a b]
  (err/raise (str (v/type-name a) " and " (v/type-name b) " cannot be " op)))

(defn merge-objects
  "`a + b` on objects: `a` with each key of `b` set in order. O(|a| + |b|)."
  [a b]
  (let [m (LinkedHashMap. (v/obj-map a))]
    (.putAll m (v/obj-map b))
    (v/new-obj m)))

(defn deep-merge-objects
  "`a * b` on objects: recursive merge, `b` wins on non-object conflicts."
  [a b]
  (let [m (LinkedHashMap. (v/obj-map a))]
    (doseq [^Map$Entry e (.entrySet (v/obj-map b))]
      (let [k (.getKey e) x (.getValue e) old (.get m k)]
        (.put m k (if (and (v/obj? old) (v/obj? x)) (deep-merge-objects old x) x))))
    (v/new-obj m)))

(defn plus [a b]
  (cond
    (nil? a) b
    (nil? b) a
    (and (instance? Double a) (instance? Double b)) (+ (double a) (double b))
    (and (string? a) (string? b)) (str a b)
    (and (vector? a) (vector? b)) (into a b)
    (and (v/obj? a) (v/obj? b)) (merge-objects a b)
    :else (type-fail "added" a b)))

(defn minus [a b]
  (cond
    (and (instance? Double a) (instance? Double b)) (- (double a) (double b))
    (and (vector? a) (vector? b)) (into [] (remove (fn [x] (some #(v/equal? x %) b))) a)
    :else (type-fail "subtracted" a b)))

(defn- repeat-string [^String s n]
  (let [n (double n)]
    (if (neg? n) nil (String/valueOf (.repeat s (int (min n Integer/MAX_VALUE)))))))

(defn times [a b]
  (cond
    (and (instance? Double a) (instance? Double b)) (* (double a) (double b))
    (and (string? a) (instance? Double b)) (repeat-string a b)
    (and (instance? Double a) (string? b)) (repeat-string b a)
    (and (v/obj? a) (v/obj? b)) (deep-merge-objects a b)
    :else (type-fail "multiplied" a b)))

(defn split-string
  "Splits `s` on the separator `sep`; an empty separator splits into code
  points, an empty `s` gives `[]`."
  [^String s ^String sep]
  (cond
    (.isEmpty s) []
    (.isEmpty sep) (let [out (transient [])]
                     (loop [i 0]
                       (if (< i (.length s))
                         (let [j (.offsetByCodePoints s i 1)]
                           (conj! out (.substring s i j))
                           (recur j))
                         (persistent! out))))
    :else (let [out (transient []) m (.length sep)]
            (loop [start 0]
              (let [j (.indexOf s sep (int start))]
                (if (neg? j)
                  (persistent! (conj! out (.substring s start)))
                  (do (conj! out (.substring s start j))
                      (recur (+ j m)))))))))

(defn divide [a b]
  (cond
    (and (instance? Double a) (instance? Double b))
    (if (zero? (double b))
      (err/raise "number and number cannot be divided because the divisor is zero")
      (/ (double a) (double b)))
    (and (string? a) (string? b)) (split-string a b)
    :else (type-fail "divided" a b)))

(defn modulo [a b]
  (if (and (instance? Double a) (instance? Double b))
    (let [x (long (double a)) y (long (double b))]
      (if (zero? y)
        (err/raise "number and number cannot be divided because the divisor is zero")
        (double (rem x y))))
    (type-fail "divided" a b)))

(defn negate [a]
  (if (instance? Double a)
    (- (double a))
    (err/raise (str (v/type-name a) " cannot be negated"))))

(defn compare-op
  "The comparison operator function for the keyword `op`
  (`:==` `:!=` `:<` `:<=` `:>` `:>=`); never throws."
  [op]
  (case op
    :== (fn [a b] (zero? (v/compare-values a b)))
    :!= (fn [a b] (not (zero? (v/compare-values a b))))
    :<  (fn [a b] (neg? (v/compare-values a b)))
    :<= (fn [a b] (not (pos? (v/compare-values a b))))
    :>  (fn [a b] (pos? (v/compare-values a b)))
    :>= (fn [a b] (not (neg? (v/compare-values a b))))))

(defn binary-op
  "The function implementing the binary operator keyword `op`."
  [op]
  (case op
    :+ plus :- minus :* times :/ divide :% modulo
    (compare-op op)))
