(ns jq.builtins
  "The builtin functions of the jq subset.

  A compiled filter (a *closure*) is a function `(fn [env input emit])` that
  calls `(emit output)` once per output, in order, and throws a jq error (see
  [[jq.error]]) on failure. Builtins are registered under `[name arity]`; each
  entry is a function from the vector of compiled argument closures to a
  closure."
  (:require [jq.access :as access]
            [jq.error :as err]
            [jq.json :as json]
            [jq.ops :as ops]
            [jq.value :as v])
  (:import (java.util ArrayList Arrays Comparator LinkedHashMap)))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Helpers

(defn collect
  "Runs the closure `f` on `input` and returns all its outputs as a vector."
  [f env input]
  (let [out (ArrayList.)]
    (f env input (fn [x] (.add out x)))
    (vec out)))

(defn- type-fail [what x]
  (err/raise (str (v/type-name x) " " what)))

;; ---------------------------------------------------------------------------
;; Simple value functions

(defn length [x]
  (cond (nil? x) 0.0
        (instance? Double x) (Math/abs (double x))
        (string? x) (double (let [^String s x] (.codePointCount s 0 (.length s))))
        (vector? x) (double (count x))
        (v/obj? x) (double (count x))
        :else (type-fail "has no length" x)))

(defn keys* [x]
  (cond (v/obj? x) (v/sorted-keys x)
        (vector? x) (mapv double (range (count x)))
        :else (type-fail "has no keys" x)))

(defn has [x k]
  (cond
    (nil? x) false
    (and (v/obj? x) (string? k)) (v/obj-has? x k)
    (and (vector? x) (instance? Double k)) (let [i (long (double k))] (and (>= i 0) (< i (count x))))
    :else (err/raise (str "Cannot check whether " (v/type-name x) " has a " (v/type-name k) " key"))))

(defn- iter-values [x]
  (let [r (access/iterable-checked x)]
    (if (identical? r access/fail) (type-fail "is not iterable" x) r)))

(defn- homogeneous-kind [xs]
  ;; The common kind (:string/:array/:object) of the non-null items, or nil
  ;; when they are mixed or of another kind.
  (reduce (fn [kind x]
            (let [k (cond (nil? x) kind
                          (string? x) :string
                          (vector? x) :array
                          (v/obj? x) :object
                          :else :other)]
              (cond (nil? x) kind
                    (nil? kind) k
                    (= kind k) kind
                    :else (reduced :mixed))))
          nil xs))

(defn add
  "Sum of the items with `+`, starting from null; linear in the total size."
  [x]
  (let [items (iter-values x)
        kind (homogeneous-kind items)]
    (case kind
      :string (let [sb (StringBuilder.)]
                (doseq [s items] (when s (.append sb ^String s)))
                (str sb))
      :array (persistent! (reduce (fn [acc a] (if a (reduce conj! acc a) acc)) (transient []) items))
      :object (let [m (LinkedHashMap.)]
                (doseq [o items] (when o (.putAll m (v/obj-map o))))
                (v/new-obj m))
      (reduce ops/plus nil items))))

(defn- sort-values [xs]
  (let [arr (object-array xs)]
    (Arrays/sort arr v/comparator-of-values)
    (vec arr)))

(deftype Keyed [k x])

(def ^:private ^Comparator keyed-comparator
  (reify Comparator
    (compare [_ a b] (int (v/compare-values (.k ^Keyed a) (.k ^Keyed b))))))

(defn- sorted-keyed
  "The array `xs` as a stably sorted Keyed[] ordered by the key `[f]` of each
  element; `f` is evaluated once per element."
  ^objects [f env xs]
  (let [arr (object-array (map (fn [x] (Keyed. (collect f env x) x)) xs))]
    (Arrays/sort arr keyed-comparator)
    arr))

(defn- require-array [x]
  (if (vector? x) x (type-fail "cannot be sorted, as it is not an array" x)))

(defn unique [x]
  (let [s (sort-values (require-array x))]
    (persistent!
     (reduce (fn [acc y]
               (if (and (pos? (count acc)) (v/equal? (nth acc (dec (count acc))) y))
                 acc
                 (conj! acc y)))
             (transient []) s))))

(defn- extremum [x keep-new?]
  (let [xs (if (vector? x) x (type-fail "cannot be iterated over for min/max" x))]
    (when (pos? (count xs))
      (reduce (fn [best y] (if (keep-new? (v/compare-values y best)) y best))
              (nth xs 0) (rest xs)))))

(defn tostring [x]
  (if (string? x) x (json/stringify x)))

(defn tonumber [x]
  (cond (instance? Double x) x
        (string? x) (or (json/parse-number x)
                        (err/raise (str "Cannot parse '" x "' as a number")))
        :else (type-fail "cannot be parsed as a number" x)))

(defn reverse* [x]
  (cond (nil? x) []
        (vector? x) (vec (rseq x))
        :else (type-fail "cannot be reversed, as it is not an array" x)))

;; ---------------------------------------------------------------------------
;; Registration

(defn- value-fn
  "A closure for a builtin computing one output from its input."
  [f]
  (fn [_] (fn [_ input emit] (emit (f input)))))

(defn- arg-fn
  "A closure for a one-argument builtin `(f input arg-output)` applied for each
  output of the argument."
  [f]
  (fn [[a]] (fn [env input emit] (a env input (fn [k] (emit (f input k)))))))

(def table
  "Map from `[name arity]` to a function building a closure from the vector of
  argument closures."
  {["empty" 0] (fn [_] (fn [_ _ _] nil))
   ["error" 0] (fn [_] (fn [_ input _] (err/raise input)))
   ["error" 1] (fn [[a]] (fn [env input _] (a env input (fn [x] (err/raise x)))))
   ["not" 0] (value-fn #(not (v/truthy? %)))
   ["length" 0] (value-fn length)
   ["keys" 0] (value-fn keys*)
   ["has" 1] (arg-fn has)
   ["type" 0] (value-fn v/type-name)
   ["add" 0] (value-fn add)
   ["select" 1] (fn [[f]]
                  (fn [env input emit]
                    (f env input (fn [c] (when (v/truthy? c) (emit input))))))
   ["map" 1] (fn [[f]]
               (fn [env input emit]
                 (let [out (ArrayList.)
                       push (fn [y] (.add out y))]
                   (doseq [x (iter-values input)] (f env x push))
                   (emit (vec out)))))
   ["sort" 0] (value-fn #(sort-values (require-array %)))
   ["sort_by" 1] (fn [[f]]
                   (fn [env input emit]
                     (emit (mapv #(.x ^Keyed %) (sorted-keyed f env (require-array input))))))
   ["group_by" 1] (fn [[f]]
                    (fn [env input emit]
                      (let [arr (sorted-keyed f env (require-array input))
                            n (alength arr)]
                        (emit
                         (loop [i 0 groups (transient []) cur nil curk nil]
                           (if (< i n)
                             (let [^Keyed e (aget arr i)]
                               (if (and cur (v/equal? curk (.k e)))
                                 (recur (inc i) groups (conj! cur (.x e)) curk)
                                 (recur (inc i)
                                        (if cur (conj! groups (persistent! cur)) groups)
                                        (transient [(.x e)]) (.k e))))
                             (persistent! (if cur (conj! groups (persistent! cur)) groups))))))))
   ["unique" 0] (value-fn unique)
   ["reverse" 0] (value-fn reverse*)
   ["min" 0] (value-fn #(extremum % neg?))
   ["max" 0] (value-fn #(extremum % (complement neg?)))
   ["tostring" 0] (value-fn tostring)
   ["tonumber" 0] (value-fn tonumber)})

(defn lookup
  "The builder for the builtin `name` of the given arity, or nil."
  [name arity]
  (get table [name arity]))
