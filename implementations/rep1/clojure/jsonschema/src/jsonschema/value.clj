(ns jsonschema.value
  "Operations on JSON values in the validator's data model (see
  [[jsonschema.json]]): type classification, exact numeric operations, and
  JSON equality with a hash that is consistent with it."
  (:import (java.math BigDecimal BigInteger RoundingMode)
           (java.util ArrayList HashMap)))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Types

(defn json-type
  "Returns the JSON type of `v` as one of `:null :boolean :number :string
  :array :object`."
  [v]
  (cond
    (nil? v) :null
    (instance? Boolean v) :boolean
    (number? v) :number
    (string? v) :string
    (map? v) :object
    (sequential? v) :array
    :else (throw (ex-info "Not a JSON value" {:value v :class (class v)}))))

;; ---------------------------------------------------------------------------
;; Numbers (exact decimals)

(defn ->decimal
  "Coerces a Clojure number to `BigDecimal` without losing information that
  the number carries."
  ^BigDecimal [n]
  (cond
    (instance? BigDecimal n) n
    (instance? BigInteger n) (BigDecimal. ^BigInteger n)
    (instance? clojure.lang.BigInt n) (BigDecimal. (biginteger n))
    (integer? n) (BigDecimal/valueOf (long n))
    (instance? clojure.lang.Ratio n) (throw (ex-info "Ratios are not JSON numbers" {:value n}))
    :else (BigDecimal. (double n))))

(defn compare-numbers
  "Three-way comparison of two numbers by exact value."
  ^long [a b]
  (long (.compareTo (->decimal a) (->decimal b))))

(defn integer-value?
  "True when the number denotes a whole number (`1.0`, `1e2`, `-0`)."
  [n]
  (let [d (->decimal n)]
    (or (zero? (.signum d))
        (<= (.scale d) 0)
        (<= (.scale (.stripTrailingZeros d)) 0))))

(defn multiple-of?
  "True when `n / divisor` is an integer, computed exactly. `divisor` must be
  non-zero."
  [n divisor]
  (let [a (->decimal n) b (->decimal divisor)]
    (zero? (.signum (.remainder a b)))))

(def ^:private ^BigDecimal long-max (BigDecimal/valueOf Long/MAX_VALUE))

(defn count-bound
  "Converts a size-limit keyword value (which may be written as `2`, `2.0`,
  `2e0`) to a `long`. `mode` is `:floor` (use for upper bounds) or `:ceiling`
  (use for lower bounds). Values beyond the `long` range are clamped."
  ^long [n mode]
  (let [d (->decimal n)]
    (cond
      (pos? (.compareTo d long-max)) Long/MAX_VALUE
      (neg? (.compareTo d (.negate long-max))) Long/MIN_VALUE
      :else (.longValue (.setScale d 0 (if (= mode :floor)
                                         RoundingMode/FLOOR
                                         RoundingMode/CEILING))))))

;; ---------------------------------------------------------------------------
;; Equality and hashing

(defn json-equal?
  "JSON equality as defined by the specification: structural, with numbers
  compared by exact value and values of different types never equal."
  [a b]
  (cond
    (identical? a b) true
    (nil? a) false
    (string? a) (and (string? b) (.equals ^String a ^String b))
    (number? a) (and (number? b) (zero? (compare-numbers a b)))
    (instance? Boolean a) (and (instance? Boolean b) (= a b))
    (map? a) (and (map? b)
                  (== (count a) (count b))
                  (every? (fn [[k v]]
                            (let [w (get b k ::missing)]
                              (and (not (identical? w ::missing)) (json-equal? v w))))
                          a))
    (sequential? a) (and (sequential? b)
                         (== (count a) (count b))
                         (every? true? (map json-equal? a b)))
    :else false))

(defn json-hash
  "A hash code for `v` such that `(json-equal? a b)` implies equal hashes."
  ^long [v]
  (cond
    (nil? v) 0
    (string? v) (long (.hashCode ^String v))
    (number? v) (let [d (->decimal v)]
                  (if (zero? (.signum d))
                    17
                    (long (.hashCode (.stripTrailingZeros d)))))
    (instance? Boolean v) (if v 1231 1237)
    (map? v) (reduce (fn [^long acc [k x]]
                       (unchecked-add acc (unchecked-multiply 31 (unchecked-add (json-hash k) (unchecked-multiply 7 (json-hash x))))))
                     (long 99) v)
    (sequential? v) (reduce (fn [^long acc x] (unchecked-add (unchecked-multiply acc 31) (json-hash x)))
                            (long 1) v)
    :else 0))

(defn all-unique?
  "True when no two elements of `xs` are JSON-equal. Expected linear time in
  the total size of the elements: elements are bucketed by [[json-hash]] and
  compared only within a bucket."
  [xs]
  (let [buckets (HashMap.)]
    (loop [s (seq xs)]
      (if-not s
        true
        (let [x (first s)
              h (json-hash x)
              ^ArrayList b (.get buckets h)]
          (cond
            (nil? b) (let [nb (ArrayList.)]
                       (.add nb x)
                       (.put buckets h nb)
                       (recur (next s)))
            (some #(json-equal? x %) b) false
            :else (do (.add b x) (recur (next s)))))))))

(defn code-point-length
  "Length of `s` in Unicode code points."
  ^long [^String s]
  (.codePointCount s 0 (.length s)))
