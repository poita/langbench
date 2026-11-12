(ns buildsys.value
  "KBL values and their total order.

  A KBL value is one of
    str   -> java.lang.String holding a *byte string* (chars 0..255)
    int   -> java.lang.Long   (64-bit, wrapping)
    bool  -> java.lang.Boolean
    list  -> a persistent vector of values

  Persistent vectors make copying a list O(1)."
  (:require [buildsys.errors :as e]))

(defn type-name
  "The KBL type token of `v`: \"str\", \"int\", \"bool\" or \"list\"."
  ^String [v]
  (cond (string? v)  "str"
        (integer? v) "int"
        (boolean? v) "bool"
        (vector? v)  "list"
        :else (throw (IllegalArgumentException. (str "not a KBL value: " (pr-str v))))))

(defn- rank ^long [v]
  (cond (boolean? v) 0 (integer? v) 1 (string? v) 2 :else 3))

(defn compare-values
  "The total order of KBL values: bool < int < str < list; within a type the
  natural order (strings by unsigned byte, lists lexicographically)."
  ^long [a b]
  (let [ra (rank a) rb (rank b)]
    (cond
      (not= ra rb) (Long/compare ra rb)
      (zero? ra)   (long (compare a b))
      (= ra 1)     (Long/compare (long a) (long b))
      (= ra 2)     (long (Integer/signum (.compareTo ^String a ^String b)))
      :else
      (let [na (count a) nb (count b) m (min na nb)]
        (loop [i 0]
          (if (< i m)
            (let [c (compare-values (nth a i) (nth b i))]
              (if (zero? c) (recur (inc i)) c))
            (Long/compare na nb)))))))

(defn type-error!
  "Throws `E_TYPE <site>: expected <expected>, got <type of v>`."
  [site expected v]
  (e/fail! "E_TYPE" (str site ": expected " expected ", got " (type-name v))))

(defn expect-str! [site v] (if (string? v) v (type-error! site "str" v)))
(defn expect-int! [site v] (if (integer? v) v (type-error! site "int" v)))
(defn expect-bool! [site v] (if (boolean? v) v (type-error! site "bool" v)))
(defn expect-list! [site v] (if (vector? v) v (type-error! site "list" v)))

(defn expect-strlist!
  "Coerces a `str` or a list of `str` into a vector of strings; anything else
  is `E_TYPE <site>: expected strlist, got ...` (naming the type of the first
  offending element for a list)."
  [site v]
  (cond (string? v) [v]
        (vector? v) (do (doseq [x v]
                          (when-not (string? x) (type-error! site "strlist" x)))
                        v)
        :else (type-error! site "strlist" v)))

(defn ->text
  "The text of an int, bool or str as produced by interpolation and `str()`."
  ^String [v]
  (cond (string? v)  v
        (integer? v) (Long/toString (long v))
        (boolean? v) (if v "true" "false")
        :else (e/fail! "E_INTERP" "list")))
