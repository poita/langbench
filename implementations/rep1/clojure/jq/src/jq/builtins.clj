(ns jq.builtins
  "The builtin functions of the supported jq subset.

  Each builtin is registered under `\"name/arity\"` with a *constructor*: a
  function taking the compiled argument filters and returning the compiled
  filter. A compiled filter is a function `(fn [env input emit])` that calls
  `(emit output)` once per output, in order, and throws a jq error to abort
  (see [[jq.interp]])."
  (:require [jq.value :as v :refer [jq-error fail num?]]
            [jq.ops :as ops])
  (:import [java.util ArrayList Arrays]
           [clojure.lang MapEntry]))

;; ---------------------------------------------------------------- helpers

(defn- each
  "Calls `(f x)` for each element of the vector `coll`."
  [coll f]
  (reduce (fn [_ x] (f x) nil) nil coll))

(defn collect
  "Runs the compiled filter `f` on `input` and returns a vector of all its
  outputs."
  [f env input]
  (let [out (ArrayList.)]
    (f env input (fn [x] (.add out x)))
    (vec out)))

(defn- value-fn
  "Wraps a one-argument value function as a zero-arity builtin."
  [f]
  (fn [_args] (fn [_env in emit] (emit (f in)))))

;; ------------------------------------------------- simple value functions

(defn- length [x]
  (cond (nil? x) 0.0
        (num? x) (Math/abs (double x))
        (string? x) (double (.codePointCount ^String x 0 (.length ^String x)))
        (vector? x) (double (count x))
        (v/object? x) (double (v/obj-count x))
        :else (fail (str (v/type-name x) " has no length"))))

(defn- keys* [x]
  (cond (v/object? x) (v/obj-sorted-keys x)
        (vector? x) (mapv double (range (count x)))
        :else (fail (str (v/type-name x) " has no keys"))))

(defn- has [x k]
  (cond
    (nil? x) false
    (and (v/object? x) (string? k)) (v/obj-has? x k)
    (and (vector? x) (num? k)) (let [i (long (double k))] (and (>= i 0) (< i (count x))))
    :else (fail (str "Cannot check whether " (v/type-name x) " has a key of type " (v/type-name k)))))

(defn- add* [x]
  (let [items (ops/elements x)
        all? (fn [pred] (every? #(or (nil? %) (pred %)) items))]
    (cond
      (all? string?) (let [sb (StringBuilder.)]
                       (each items #(when % (.append sb ^String %)))
                       (if (every? nil? items) nil (.toString sb)))
      (all? vector?) (if (every? nil? items)
                       nil
                       (persistent! (reduce (fn [acc x] (if x (reduce conj! acc x) acc))
                                            (transient []) items)))
      :else (reduce ops/add nil items))))

(defn- sort* [x]
  (if (vector? x)
    (let [arr (to-array x)]
      (Arrays/sort arr v/comparator-values)
      (vec arr))
    (fail (str (v/type-name x) " cannot be sorted, as it is not an array"))))

(defn- unique* [x]
  (let [sorted (sort* x)]
    (if (empty? sorted)
      sorted
      (persistent!
       (reduce (fn [acc y] (if (v/equal? (nth acc (dec (count acc))) y) acc (conj! acc y)))
               (transient [(first sorted)]) (rest sorted))))))

(defn- reverse* [x]
  (cond (nil? x) []
        (vector? x) (vec (rseq x))
        :else (fail (str "Cannot reverse " (v/type-name x)))))

(defn- extremum [x better?]
  (if (vector? x)
    (if (empty? x)
      nil
      (reduce (fn [best y] (if (better? (v/compare-values y best)) y best)) (first x) (rest x)))
    (fail (str "Cannot take min/max of " (v/type-name x)))))

(def ^:private number-pattern
  #"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?")

(defn- tonumber [x]
  (cond
    (num? x) x
    (and (string? x) (re-matches number-pattern x)) (Double/valueOf (Double/parseDouble x))
    :else (fail (str (v/type-name x) " cannot be parsed as a number"))))

;; ----------------------------------------------------- stream builtins

(defn- sort-keyed
  "Pairs each element of the array `x` with its sort key `[f]` (one
  evaluation of `f` per element) and returns the pairs stably sorted by key."
  [f env x]
  (when-not (vector? x)
    (fail (str (v/type-name x) " cannot be sorted, as it is not an array")))
  (let [arr (object-array (count x))]
    (dotimes [i (count x)]
      (let [e (nth x i)]
        (aset arr i (MapEntry/create (collect f env e) e))))
    (Arrays/sort arr (reify java.util.Comparator
                       (compare [_ a b] (v/compare-values (.key ^MapEntry a) (.key ^MapEntry b)))))
    arr))

(defn- sort-by* [[f]]
  (fn [env in emit]
    (emit (let [arr (sort-keyed f env in)]
            (persistent! (reduce (fn [acc ^MapEntry p] (conj! acc (.val p))) (transient []) arr))))))

(defn- group-by* [[f]]
  (fn [env in emit]
    (let [arr (sort-keyed f env in)
          n (alength arr)]
      (emit
       (if (zero? n)
         []
         (loop [i 1
                cur-key (.key ^MapEntry (aget arr 0))
                cur (transient [(.val ^MapEntry (aget arr 0))])
                out (transient [])]
           (if (< i n)
             (let [^MapEntry p (aget arr i)]
               (if (v/equal? cur-key (.key p))
                 (recur (inc i) cur-key (conj! cur (.val p)) out)
                 (recur (inc i) (.key p) (transient [(.val p)]) (conj! out (persistent! cur)))))
             (persistent! (conj! out (persistent! cur))))))))))

(defn- map* [[f]]
  (fn [env in emit]
    (let [items (ops/elements in)
          out (ArrayList.)]
      (each items (fn [x] (f env x (fn [y] (.add out y)))))
      (emit (vec out)))))

(defn- select* [[f]]
  (fn [env in emit]
    (f env in (fn [c] (when c (emit in))))))

(defn- has* [[f]]
  (fn [env in emit]
    (f env in (fn [k] (emit (has in k))))))

(def registry
  "Map from `\"name/arity\"` to the builtin's constructor."
  {"empty/0" (fn [_] (fn [_env _in _emit] nil))
   "error/0" (fn [_] (fn [_env in _emit] (throw (jq-error in))))
   "error/1" (fn [[f]] (fn [env in _emit] (f env in (fn [x] (throw (jq-error x))))))
   "not/0" (value-fn (fn [x] (not x)))
   "length/0" (value-fn length)
   "keys/0" (value-fn keys*)
   "type/0" (value-fn v/type-name)
   "add/0" (value-fn add*)
   "sort/0" (value-fn sort*)
   "unique/0" (value-fn unique*)
   "reverse/0" (value-fn reverse*)
   "min/0" (value-fn #(extremum % neg?))
   "max/0" (value-fn #(extremum % (complement neg?)))
   "tostring/0" (value-fn ops/to-string)
   "tonumber/0" (value-fn tonumber)
   "has/1" has*
   "select/1" select*
   "map/1" map*
   "sort_by/1" sort-by*
   "group_by/1" group-by*})

(defn compile-call
  "Returns the compiled filter for builtin `name` applied to the compiled
  argument filters `args`. Throws `ex-info` (`{:type :jq/parse-error}`) for
  an unknown builtin."
  [name args]
  (if-let [ctor (get registry (str name "/" (count args)))]
    (ctor args)
    (throw (ex-info (str "unknown function " name "/" (count args))
                    {:type :jq/parse-error}))))
