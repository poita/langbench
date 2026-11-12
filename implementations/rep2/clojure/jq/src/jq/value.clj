(ns jq.value
  "The jq data model.

  | jq        | Clojure representation                         |
  |-----------|------------------------------------------------|
  | null      | `nil`                                          |
  | boolean   | `true` / `false`                               |
  | number    | `java.lang.Double` (always a double)           |
  | string    | `java.lang.String`                             |
  | array     | persistent vector                              |
  | object    | [[Obj]], an insertion-ordered immutable map    |

  Values are immutable and freely shared; nothing is ever deep-copied."
  (:import (java.util Arrays Comparator LinkedHashMap Map$Entry)
           (clojure.lang MapEntry)))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Ordering of strings

(defn- fix-surrogate ^long [^long c]
  (cond (< c 0xD800) c
        (>= c 0xE000) (- c 0x800)
        :else (+ c 0x2000)))

(defn compare-strings
  "Compares two strings by Unicode code point (not by UTF-16 unit)."
  ^long [^String a ^String b]
  (let [la (.length a) lb (.length b) n (min la lb)]
    (loop [i 0]
      (if (< i n)
        (let [ca (long (int (.charAt a i))) cb (long (int (.charAt b i)))]
          (if (== ca cb)
            (recur (inc i))
            (if (< (fix-surrogate ca) (fix-surrogate cb)) -1 1)))
        (Long/compare la lb)))))

(def ^:private ^Comparator string-comparator
  (reify Comparator
    (compare [_ a b] (int (compare-strings a b)))))

;; ---------------------------------------------------------------------------
;; Objects

(declare compare-values)

(defprotocol SortedKeys
  (sorted-keys [o]
    "The keys of the object sorted by code point, as a vector of strings.
    Computed at most once per object."))

(deftype Obj [^LinkedHashMap m ^:unsynchronized-mutable ks]
  SortedKeys
  (sorted-keys [_]
    (or ks
        (let [a (.toArray (.keySet m) ^"[Ljava.lang.String;" (make-array String 0))]
          (Arrays/sort ^objects a string-comparator)
          (set! ks (vec a))
          ks)))
  clojure.lang.Counted
  (count [_] (.size m))
  clojure.lang.ILookup
  (valAt [_ k] (.get m k))
  (valAt [_ k not-found] (if (.containsKey m k) (.get m k) not-found))
  clojure.lang.Seqable
  (seq [_]
    (when (pos? (.size m))
      (map (fn [^Map$Entry e] (MapEntry/create (.getKey e) (.getValue e)))
           (.entrySet m))))
  Object
  (equals [this other]
    (and (instance? Obj other) (zero? (compare-values this other))))
  (hashCode [_]
    (reduce (fn [^long h ^Map$Entry e]
              (unchecked-add h (long (bit-xor (hash (.getKey e)) (hash (.getValue e))))))
            0 (.entrySet m)))
  (toString [this] (str "#jq/obj " (pr-str (into [] (seq this))))))

(defmethod print-method Obj [o ^java.io.Writer w]
  (.write w (str "#jq/obj " (pr-str (into [] (seq o))))))

(defn obj?
  "True when `x` is a jq object."
  [x]
  (instance? Obj x))

(defn new-obj
  "Wraps a `java.util.LinkedHashMap` as an object. The caller must not mutate
  the map afterwards."
  ^Obj [^LinkedHashMap m]
  (Obj. m nil))

(def empty-obj (Obj. (LinkedHashMap.) nil))

(defn obj-map
  "The underlying (read-only!) `LinkedHashMap` of an object."
  ^LinkedHashMap [^Obj o]
  (.m o))

(defn obj-get
  "The value under string key `k`, or nil."
  [^Obj o k]
  (.get (obj-map o) k))

(defn obj-has?
  "Whether the object has the string key `k`."
  [^Obj o k]
  (.containsKey (obj-map o) k))

(defn obj-from-pairs
  "Builds an object from a sequence of `[k v]` pairs, left to right. A repeated
  key keeps its first position but takes its last value."
  [pairs]
  (let [m (LinkedHashMap.)]
    (doseq [[k v] pairs] (.put m k v))
    (new-obj m)))

;; ---------------------------------------------------------------------------
;; Ordering

(defn- rank ^long [v]
  (cond (nil? v) 0
        (instance? Boolean v) (if v 2 1)
        (instance? Double v) 3
        (string? v) 4
        (vector? v) 5
        :else 6))

(declare compare-vectors compare-objects)

(defn compare-values
  "Total order on jq values: null < false < true < numbers < strings < arrays <
  objects, then within each type as described in the specification. Returns a
  negative, zero or positive number."
  ^long [a b]
  (let [ra (rank a) rb (rank b)]
    (cond
      (< ra rb) -1
      (> ra rb) 1
      :else (case ra
              3 (let [x (double a) y (double b)]
                  (cond (< x y) -1 (> x y) 1 :else 0))
              4 (compare-strings a b)
              5 (compare-vectors a b)
              6 (compare-objects a b)
              0))))

(defn- compare-vectors ^long [a b]
  (let [na (count a) nb (count b) n (min na nb)]
    (loop [i 0]
      (if (< i n)
        (let [c (compare-values (nth a i) (nth b i))]
          (if (zero? c) (recur (inc i)) c))
        (Long/compare na nb)))))

(defn- compare-objects ^long [^Obj a ^Obj b]
  (let [ka (sorted-keys a) kb (sorted-keys b)
        c (compare-vectors ka kb)]
    (if-not (zero? c)
      c
      (let [ma (obj-map a) mb (obj-map b) n (count ka)]
        (loop [i 0]
          (if (< i n)
            (let [k (nth ka i)
                  c (compare-values (.get ma k) (.get mb k))]
              (if (zero? c) (recur (inc i)) c))
            0))))))

(defn equal?
  "jq equality: values compare equal under [[compare-values]]."
  [a b]
  (zero? (compare-values a b)))

(def ^Comparator comparator-of-values
  "A `java.util.Comparator` implementing [[compare-values]]."
  (reify Comparator
    (compare [_ a b] (int (compare-values a b)))))

;; ---------------------------------------------------------------------------
;; Misc

(defn truthy?
  "jq truthiness: everything except `false` and `null` is true."
  [v]
  (not (or (nil? v) (identical? v false))))

(defn type-name
  "The jq type name of a value."
  [v]
  (case (rank v)
    0 "null" (1 2) "boolean" 3 "number" 4 "string" 5 "array" 6 "object"))

(defn ->clj
  "Converts a jq value to plain Clojure data. Objects become maps (with string
  keys, or keywords when `keywordize?`); note that Clojure maps do not keep
  insertion order beyond eight keys."
  ([v] (->clj v false))
  ([v keywordize?]
   (cond
     (instance? Obj v) (into {} (map (fn [[k x]] [(if keywordize? (keyword k) k)
                                                  (->clj x keywordize?)]))
                             (seq v))
     (vector? v) (mapv #(->clj % keywordize?) v)
     :else v)))

(defn clj->
  "Converts Clojure data to a jq value: maps become objects (keys must be
  strings, keywords or symbols), sequential collections arrays, numbers
  doubles. Ordered input maps (`array-map`, sorted) keep their order."
  [x]
  (cond
    (nil? x) nil
    (instance? Boolean x) x
    (number? x) (double x)
    (string? x) x
    (instance? Obj x) x
    (keyword? x) (name x)
    (map? x) (obj-from-pairs (map (fn [[k v]] [(if (string? k) k (name k)) (clj-> v)]) x))
    (or (sequential? x) (set? x)) (mapv clj-> x)
    :else (throw (IllegalArgumentException. (str "Cannot convert to a jq value: " (pr-str x))))))
