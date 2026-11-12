(ns buildsys.value
  "KBL values and their operations.

  A value is one of: a byte string (`String`, one char per byte), an integer
  (`Long`), a boolean, or a list (a persistent vector of values)."
  (:require [buildsys.error :as err]))

(set! *warn-on-reflection* true)

(defn type-name
  "The KBL type token of value `v`: \"str\", \"int\", \"bool\" or \"list\"."
  [v]
  (cond (string? v) "str"
        (integer? v) "int"
        (boolean? v) "bool"
        (vector? v) "list"
        :else (throw (IllegalArgumentException. (str "not a KBL value: " (pr-str v))))))

(defn- rank ^long [v]
  (cond (boolean? v) 0 (integer? v) 1 (string? v) 2 :else 3))

(defn compare-values
  "The total order on values: bool < int < str < list; see SPEC.md."
  [a b]
  (let [ra (rank a) rb (rank b)]
    (cond
      (not= ra rb) (compare ra rb)
      (== ra 3)
      (let [^clojure.lang.IPersistentVector a a
            ^clojure.lang.IPersistentVector b b
            na (count a) nb (count b)
            m (min na nb)]
        (loop [i 0]
          (if (< i m)
            (let [c (compare-values (nth a i) (nth b i))]
              (if (zero? c) (recur (inc i)) c))
            (compare na nb))))
      :else (compare a b))))

(defn type-error
  "Throw `E_TYPE <site>: expected <expected>, got <type of v>`."
  [site expected v]
  (err/fail "E_TYPE" (str site ": expected " expected ", got " (type-name v))))

(defn expect-type
  "Check that `v` satisfies `pred`, else throw an `E_TYPE` error."
  [site expected pred v]
  (when-not (pred v) (type-error site expected v))
  v)

(defn to-text
  "The text of `v` as produced by interpolation and `str()`.  A list is an
  `E_INTERP` error."
  [v]
  (cond (string? v) v
        (integer? v) (str v)
        (boolean? v) (if v "true" "false")
        :else (err/fail "E_INTERP" "list")))

(defn strlist
  "Check that `v` is a string or a list of strings (type token `strlist`) and
  return it as a vector of strings."
  [site v]
  (cond
    (string? v) [v]
    (vector? v) (do (doseq [x v]
                      (when-not (string? x) (type-error site "strlist" x)))
                    v)
    :else (type-error site "strlist" v)))
