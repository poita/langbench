(ns jq.access
  "Field/index access, slicing and iteration (`.a`, `.[k]`, `.[a:b]`, `.[]`).

  Each `*-checked` function returns the sentinel [[fail]] instead of throwing
  when the operation does not apply to its operands. This lets the evaluator
  implement the per-operation `?` without exceptions, and the strict forms
  ([[index]], [[slice]], [[iterable]]) throw a jq error on failure."
  (:require [jq.error :as err]
            [jq.value :as v]))

(set! *warn-on-reflection* true)

(def fail
  "Sentinel returned by the `*-checked` functions when the operation fails."
  (Object.))

(defn index-checked
  "`t[k]` or [[fail]]."
  [t k]
  (cond
    (string? k) (cond (v/obj? t) (v/obj-get t k)
                      (nil? t) nil
                      :else fail)
    (instance? Double k) (cond
                           (vector? t)
                           (let [n (count t)
                                 i (long k)
                                 i (if (neg? i) (+ n i) i)]
                             (when (and (>= i 0) (< i n)) (nth t i)))
                           (nil? t) nil
                           :else fail)
    :else fail))

(defn iterable-checked
  "The elements of an array or the values of an object (a Java `Iterable`/
  vector), or [[fail]]."
  [t]
  (cond (vector? t) t
        (v/obj? t) (.values (v/obj-map t))
        :else fail))

(defn- clamp ^long [^long x ^long len]
  (max 0 (min x len)))

(defn- bound ^long [x ^long len default floor?]
  (if (nil? x)
    default
    (let [d (double x)
          i (long (if floor? (Math/floor d) (Math/ceil d)))]
      (clamp (if (neg? i) (+ len i) i) len))))

(defn slice-checked
  "`t[from:to]` (either bound may be nil for 'absent') or [[fail]]."
  [t from to]
  (cond
    (nil? t) (if (and (or (nil? from) (instance? Double from))
                      (or (nil? to) (instance? Double to)))
               nil
               fail)
    (not (or (vector? t) (string? t))) fail
    (not (and (or (nil? from) (instance? Double from))
              (or (nil? to) (instance? Double to)))) fail
    (string? t)
    (let [^String s t
          len (.codePointCount s 0 (.length s))
          a (bound from len 0 true)
          b (max a (bound to len len false))]
      (if (== len (.length s))
        (.substring s a b)
        (.substring s (.offsetByCodePoints s 0 a) (.offsetByCodePoints s 0 b))))
    :else
    (let [len (count t)
          a (bound from len 0 true)
          b (max a (bound to len len false))]
      (subvec t a b))))

(defn- type-error [what t]
  (err/jq-error (str "Cannot " what " " (v/type-name t))))

(defn index
  "`t[k]`; throws a jq error if the index does not apply."
  [t k]
  (let [r (index-checked t k)]
    (if (identical? r fail)
      (throw (type-error (str "index with " (v/type-name k) " on") t))
      r)))

(defn slice
  "`t[from:to]`; throws a jq error if the slice does not apply."
  [t from to]
  (let [r (slice-checked t from to)]
    (if (identical? r fail)
      (throw (type-error "slice" t))
      r)))

(defn iterable
  "The elements of `t` for `.[]`; throws a jq error if `t` is not iterable."
  [t]
  (let [r (iterable-checked t)]
    (if (identical? r fail)
      (throw (type-error "iterate over" t))
      r)))
