(ns jq.ops
  "Value-level operations: arithmetic, comparison, indexing, slicing and
  iteration. Every function takes and returns jq values and throws a jq error
  (see [[jq.value/jq-error]]) for type combinations the language rejects."
  (:require [jq.value :as v :refer [fail num?]]
            [jq.json :as json]))

(defn- type-error [what a b]
  (fail (str (v/type-name a) " and " (v/type-name b) " cannot be " what)))

;; ------------------------------------------------------------ arithmetic

(defn add
  "`a + b`."
  [a b]
  (cond
    (nil? a) b
    (nil? b) a
    (and (num? a) (num? b)) (+ (double a) (double b))
    (and (string? a) (string? b)) (.concat ^String a ^String b)
    (and (vector? a) (vector? b)) (into a b)
    (and (v/object? a) (v/object? b)) (v/obj-merge a b)
    :else (type-error "added" a b)))

(defn subtract
  "`a - b`."
  [a b]
  (cond
    (and (num? a) (num? b)) (- (double a) (double b))
    (and (vector? a) (vector? b))
    (if (empty? b)
      a
      (into [] (remove (fn [x] (some #(v/equal? x %) b))) a))
    :else (type-error "subtracted" a b)))

(defn- repeat-string [^String s k]
  (let [d (double k)]
    (if (neg? d)
      nil
      (let [n (long d)]
        (if (or (zero? n) (.isEmpty s))
          ""
          (let [sb (StringBuilder. (* n (.length s)))]
            (dotimes [_ n] (.append sb s))
            (.toString sb)))))))

(defn multiply
  "`a * b`."
  [a b]
  (cond
    (and (num? a) (num? b)) (* (double a) (double b))
    (and (string? a) (num? b)) (repeat-string a b)
    (and (num? a) (string? b)) (repeat-string b a)
    (and (v/object? a) (v/object? b)) (v/obj-deep-merge a b)
    :else (type-error "multiplied" a b)))

(defn split-string
  "Splits `s` on `sep` into a vector of strings; an empty separator splits
  into code points and an empty `s` gives `[]`."
  [^String s ^String sep]
  (cond
    (.isEmpty s) []
    (.isEmpty sep) (persistent!
                    (loop [i 0 acc (transient [])]
                      (if (< i (.length s))
                        (let [j (.offsetByCodePoints s i 1)]
                          (recur j (conj! acc (.substring s i j))))
                        acc)))
    :else (let [m (.length sep)]
            (loop [from 0 acc (transient [])]
              (let [i (.indexOf s sep (int from))]
                (if (neg? i)
                  (persistent! (conj! acc (.substring s from)))
                  (recur (+ i m) (conj! acc (.substring s from i)))))))))

(defn divide
  "`a / b`."
  [a b]
  (cond
    (and (num? a) (num? b))
    (if (zero? (double b))
      (fail "number and number cannot be divided because the divisor is zero")
      (/ (double a) (double b)))
    (and (string? a) (string? b)) (split-string a b)
    :else (type-error "divided" a b)))

(defn modulo
  "`a % b`: both operands truncated to integers, result has the sign of `a`."
  [a b]
  (if (and (num? a) (num? b))
    (let [y (long (double b))]
      (if (zero? y)
        (fail "number and number cannot be divided because the divisor is zero")
        (double (rem (long (double a)) y))))
    (type-error "divided" a b)))

(defn negate
  "Unary minus."
  [a]
  (if (num? a) (- (double a)) (fail (str (v/type-name a) " cannot be negated"))))

;; ------------------------------------------------------------ comparison

(defn equal [a b] (v/equal? a b))
(defn not-equal [a b] (not (v/equal? a b)))
(defn less [a b] (neg? (v/compare-values a b)))
(defn less-equal [a b] (not (pos? (v/compare-values a b))))
(defn greater [a b] (pos? (v/compare-values a b)))
(defn greater-equal [a b] (not (neg? (v/compare-values a b))))

(def binary-ops
  "Map from operator keyword to its two-argument function."
  {:+ add :- subtract :* multiply :/ divide :% modulo
   :== equal :!= not-equal :< less :<= less-equal :> greater :>= greater-equal})

;; --------------------------------------------------- paths: index, iterate

(defn index
  "`t[k]`: field lookup (string `k`) or element lookup (number `k`)."
  [t k]
  (cond
    (string? k)
    (cond (v/object? t) (v/obj-get t k)
          (nil? t) nil
          :else (fail (str "Cannot index " (v/type-name t) " with \"" k "\"")))
    (num? k)
    (cond (vector? t) (let [n (count t)
                            i (long (double k))
                            i (if (neg? i) (+ i n) i)]
                        (if (and (>= i 0) (< i n)) (nth t i) nil))
          (nil? t) nil
          :else (fail (str "Cannot index " (v/type-name t) " with number")))
    :else (fail (str "Cannot index " (v/type-name t) " with " (v/type-name k)))))

(defn elements
  "The values `t[]` iterates over, as a vector; errors for non-iterables."
  [t]
  (cond (vector? t) t
        (v/object? t) (v/obj-vals t)
        :else (fail (str "Cannot iterate over " (v/type-name t)))))

(defn- slice-bound ^long [x ^long len ^long dflt ceil?]
  (if (nil? x)
    dflt
    (if (num? x)
      (let [d (double x)
            d (if (neg? d) (+ d len) d)
            d (if ceil? (Math/ceil d) (Math/floor d))]
        (long (Math/max 0.0 (Math/min d (double len)))))
      (fail "Start and end indices of an array slice must be numbers"))))

(defn slice
  "`t[from:to]` on arrays and strings (by code point); nil bounds are open."
  [t from to]
  (cond
    (nil? t) nil
    (vector? t) (let [len (count t)
                      s (slice-bound from len 0 false)
                      e (Math/max s (slice-bound to len len true))]
                  (subvec t s e))
    (string? t) (let [^String t t
                      len (.codePointCount t 0 (.length t))
                      s (slice-bound from len 0 false)
                      e (Math/max s (slice-bound to len len true))]
                  (if (== len (.length t))
                    (.substring t s e)
                    (.substring t (.offsetByCodePoints t 0 s) (.offsetByCodePoints t 0 e))))
    :else (fail (str "Cannot index " (v/type-name t) " with object"))))

;; -------------------------------------------------------------- tostring

(defn to-string
  "`tostring`: strings are returned as is, anything else as compact JSON."
  [x]
  (if (string? x) x (json/stringify x)))
