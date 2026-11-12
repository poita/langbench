(ns template.filters
  "The thirteen built-in filters."
  (:require [template.errors :as err]
            [template.values :as v :refer [undefined?]])
  (:import (java.math BigDecimal)))

(set! *warn-on-reflection* true)

(def names
  "The set of known filter names."
  #{"upper" "lower" "trim" "escape" "replace" "length" "int" "join"
    "first" "last" "reverse" "sort" "default"})

(defn known? [name] (contains? names name))

(defn- arity! [args lo hi]
  (let [n (count args)]
    (when (or (< n lo) (> n hi))
      (err/fail :type "wrong number of filter arguments"))))

(defn- ascii-map ^String [^String s upper?]
  (let [n (.length s)
        sb (StringBuilder. n)]
    (dotimes [i n]
      (let [c (.charAt s i)]
        (.append sb
                 (cond
                   (and upper? (<= (int \a) (int c) (int \z))) (char (- (int c) 32))
                   (and (not upper?) (<= (int \A) (int c) (int \Z))) (char (+ (int c) 32))
                   :else c))))
    (.toString sb)))

(defn- escape-html ^String [^String s]
  (let [sb (StringBuilder. (.length s))]
    (dotimes [i (.length s)]
      (let [c (.charAt s i)]
        (case c
          \& (.append sb "&amp;")
          \< (.append sb "&lt;")
          \> (.append sb "&gt;")
          \" (.append sb "&#34;")
          \' (.append sb "&#39;")
          (.append sb c))))
    (.toString sb)))

(def ^:private int-re #"[+-]?[0-9]+")
(def ^:private decimal-re #"[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?")

(defn- to-int [x]
  (cond
    (instance? Long x) x
    (instance? Double x) (long (double x))
    (instance? Boolean x) (if (.booleanValue ^Boolean x) 1 0)
    (string? x)
    (let [s (v/trim-whitespace x)]
      (cond
        (re-matches int-re s) (.longValue (java.math.BigInteger. (if (.startsWith ^String s "+") (subs s 1) s)))
        (re-matches decimal-re s) (.longValue (.toBigInteger (BigDecimal. ^String s)))
        :else 0))
    :else 0))

(defn- length-of [x]
  (cond
    (string? x) (v/code-point-length x)
    (vector? x) (long (count x))
    (v/dict? x) (long (.size ^java.util.LinkedHashMap x))
    :else (err/fail :type "object has no length")))

(defn- join [x sep]
  (let [xs (v/sequence-view x)
        sep (v/to-str sep)
        sb (StringBuilder.)]
    (dotimes [i (count xs)]
      (when (pos? i) (.append sb ^String sep))
      (v/write-str! sb (nth xs i)))
    (.toString sb)))

(defn- end-of [x first?]
  (if (string? x)
    (let [^String s x n (.length s)]
      (if (zero? n)
        v/undefined
        (if first?
          (.substring s 0 (Character/charCount (.codePointAt s 0)))
          (.substring s (.offsetByCodePoints s n -1)))))
    (let [xs (v/sequence-view x)]
      (if (empty? xs) v/undefined (if first? (nth xs 0) (nth xs (dec (count xs))))))))

(defn- sort-values [x]
  (let [xs (v/sequence-view x)]
    (cond
      (empty? xs) []
      (every? v/number-value? xs) (vec (sort v/compare-numbers xs))
      (every? string? xs) (->> xs
                               (map (fn [s] [(ascii-map s false) s]))
                               (sort (fn [a b] (v/compare-strings (nth a 0) (nth b 0))))
                               (mapv #(nth % 1)))
      :else (err/fail :type "cannot sort values of mixed or unordered kinds"))))

(defn apply-filter
  "Apply the filter `name` to the evaluated input `x` and evaluated `args`
  (a vector). Except for `default`, an undefined input is an `undefined`
  error; a wrong argument count is a `type` error."
  [name x args]
  (if (= name "default")
    (do (arity! args 0 1)
        (if (undefined? x) (if (seq args) (nth args 0) "") x))
    (do
      (when (undefined? x) (err/fail :undefined "filter applied to an undefined value"))
      (case name
        "upper" (do (arity! args 0 0) (ascii-map (v/to-str x) true))
        "lower" (do (arity! args 0 0) (ascii-map (v/to-str x) false))
        "trim" (do (arity! args 0 0) (v/trim-whitespace (v/to-str x)))
        "escape" (do (arity! args 0 0) (escape-html (v/to-str x)))
        "replace" (do (arity! args 2 2)
                      (let [s (v/to-str x) old (v/to-str (nth args 0)) new (v/to-str (nth args 1))]
                        (.replace ^String s ^CharSequence old ^CharSequence new)))
        "length" (do (arity! args 0 0) (length-of x))
        "int" (do (arity! args 0 0) (to-int x))
        "join" (do (arity! args 0 1) (join x (if (seq args) (nth args 0) "")))
        "first" (do (arity! args 0 0) (end-of x true))
        "last" (do (arity! args 0 0) (end-of x false))
        "reverse" (do (arity! args 0 0)
                      (if (string? x)
                        (.toString (.reverse (StringBuilder. ^String x)))
                        (vec (rseq (v/sequence-view x)))))
        "sort" (do (arity! args 0 0) (sort-values x))))))
