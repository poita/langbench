(ns sitegen.template.filters
  "The thirteen built-in filters of the template language."
  (:require [sitegen.template.value :as v]
            [sitegen.util :as util])
  (:import (java.util ArrayList Collections List)))

(set! *warn-on-reflection* true)

(defn- ascii-case
  "Converts ASCII letters of `s` to upper or lower case."
  ^String [^String s upper?]
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

(defn- white? [c] (case c (\space \tab \newline \return \formfeed \u000B) true false))

(defn- trim-ws ^String [^String s]
  (let [n (.length s)
        b (loop [i 0] (if (and (< i n) (white? (.charAt s i))) (recur (inc i)) i))
        e (loop [j n] (if (and (> j b) (white? (.charAt s (dec j)))) (recur (dec j)) j))]
    (.substring s b e)))

(defn- escape-html ^String [^String s]
  (let [sb (StringBuilder. (+ (.length s) 8))]
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

(defn- int-filter [x]
  (cond
    (instance? Long x) x
    (instance? Double x) (long (double x))
    (instance? Boolean x) (if ^boolean x 1 0)
    (string? x)
    (let [s (trim-ws x)]
      (cond
        (re-matches #"[+-]?[0-9]+" s)
        (try (Long/parseLong (if (.startsWith s "+") (.substring s 1) s))
             (catch NumberFormatException _ (long (.doubleValue (java.math.BigDecimal. ^String (if (.startsWith s "+") (.substring s 1) s))))))

        (re-matches #"[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?" s)
        (long (Double/parseDouble s))

        :else 0))
    :else 0))

(defn- sort-filter [x]
  (let [items (ArrayList. (v/sequence-view x))]
    (cond
      (every? v/number-value? items)
      (let [num (fn [a] (if (instance? Boolean a) (if ^boolean a 1 0) a))]
        (Collections/sort items (reify java.util.Comparator
                                  (compare [_ a b] (int (compare (num a) (num b))))))
        items)

      (every? string? items)
      (let [keyed (mapv (fn [s] [(ascii-case s false) s]) items)]
        (mapv second (sort (fn [[ka _] [kb _]] (util/compare-code-points ka kb)) keyed)))

      :else (v/error! :type "cannot sort a mixed sequence"))))

(defn- reverse-filter [x]
  (if (string? x)
    (.toString (.reverse (StringBuilder. ^String x)))
    (vec (rseq (vec (v/sequence-view x))))))

(defn- length-filter [x]
  (cond
    (string? x) (v/code-point-length x)
    (instance? java.util.Collection x) (long (.size ^java.util.Collection x))
    (instance? java.util.Map x) (long (.size ^java.util.Map x))
    :else (v/error! :type "object has no length")))

(defn- join-filter
  ([x] (join-filter x ""))
  ([x sep]
   (let [sep (v/to-str sep)
         sb (StringBuilder.)]
     (loop [s (seq (v/sequence-view x)) first? true]
       (when s
         (when-not first? (.append sb sep))
         (.append sb (v/to-str (first s)))
         (recur (next s) false)))
     (.toString sb))))

(defn- seq-end [x pick]
  (let [^List l (v/sequence-view x)]
    (if (.isEmpty l) v/undefined (.get l (int (pick (.size l)))))))

(def ^:private filters
  "Filter name -> [min-args max-args implementation] (the arguments after the
  filtered value)."
  {"upper"   [0 0 (fn [x] (ascii-case (v/to-str x) true))]
   "lower"   [0 0 (fn [x] (ascii-case (v/to-str x) false))]
   "trim"    [0 0 (fn [x] (trim-ws (v/to-str x)))]
   "escape"  [0 0 (fn [x] (escape-html (v/to-str x)))]
   "replace" [2 2 (fn [x old new] (.replace (v/to-str x) (v/to-str old) (v/to-str new)))]
   "length"  [0 0 length-filter]
   "int"     [0 0 int-filter]
   "join"    [0 1 join-filter]
   "first"   [0 0 (fn [x] (seq-end x (fn [_] 0)))]
   "last"    [0 0 (fn [x] (seq-end x dec))]
   "reverse" [0 0 reverse-filter]
   "sort"    [0 0 sort-filter]
   "default" [0 1 (fn ([x] (if (v/undefined? x) "" x))
                    ([x d] (if (v/undefined? x) d x)))]})

(defn known?
  "True when `name` is one of the built-in filters."
  [name]
  (contains? filters name))

(defn apply-filter
  "Applies the filter `name` to the value `x` with the evaluated `args`.
  Except for `default`, an undefined `x` is an `undefined` error; a wrong
  number of arguments is a `type` error."
  [name x args]
  (let [[lo hi f] (get filters name)
        n (count args)]
    (when-not (= name "default") (v/defined! x))
    (when (or (< n (long lo)) (> n (long hi)))
      (v/error! :type (str "wrong number of arguments for filter " name)))
    (apply f x args)))
