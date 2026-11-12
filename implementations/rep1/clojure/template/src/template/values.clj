(ns template.values
  "The template value model.

  | template kind | Clojure/Java representation                      |
  |---------------|--------------------------------------------------|
  | integer       | `Long`                                           |
  | float         | `Double`                                         |
  | boolean       | `Boolean`                                        |
  | none          | `nil`                                            |
  | string        | `String`                                         |
  | list          | persistent vector                                |
  | dict          | `java.util.LinkedHashMap` (never mutated once built) |
  | macro         | [[Macro]] record                                 |
  | undefined     | the keyword [[undefined]]                        |

  Values are shared, never copied: binding, passing and returning a value is
  O(1)."
  (:require [template.errors :as err])
  (:import (java.math BigDecimal)
           (java.util LinkedHashMap Map)))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Special values

(def undefined
  "The undefined value."
  ::undefined)

(defn undefined? [x] (identical? x undefined))

(def range-builtin
  "The value of the built-in `range` callable."
  ::range)

(defrecord Macro [name params body scope rc])

(defrecord Super [rc name index])

(defn macro? [x] (instance? Macro x))

;; ---------------------------------------------------------------------------
;; Kind predicates

(defn dict? [x] (instance? LinkedHashMap x))
(defn list-value? [x] (vector? x))
(defn integer-value? [x] (instance? Long x))
(defn float-value? [x] (instance? Double x))
(defn number-value?
  "True for integers, floats and booleans (booleans are integers)."
  [x]
  (or (instance? Long x) (instance? Double x) (instance? Boolean x)))

(defn int-like?
  "True for integers and booleans."
  [x]
  (or (instance? Long x) (instance? Boolean x)))

(defn ->num
  "Booleans become 0/1; other numbers are returned unchanged."
  [x]
  (if (instance? Boolean x) (if ^boolean x 1 0) x))

;; ---------------------------------------------------------------------------
;; Strings

(defn whitespace-char?
  "The six whitespace characters: space, TAB, LF, VT, FF and CR."
  [c]
  (let [c (long c)]
    (or (== c 32) (and (>= c 9) (<= c 13)))))

(defn trim-whitespace
  "Remove leading and trailing whitespace (the six characters)."
  ^String [^String s]
  (let [n (.length s)
        a (loop [i 0] (if (and (< i n) (whitespace-char? (.charAt s i))) (recur (inc i)) i))
        b (loop [j n] (if (and (> j a) (whitespace-char? (.charAt s (dec j)))) (recur (dec j)) j))]
    (if (and (zero? a) (== b n)) s (.substring s a b))))

(defn code-point-length ^long [^String s]
  (.codePointCount s 0 (.length s)))

(defn string-chars
  "The string as a vector of one-code-point strings."
  [^String s]
  (let [n (.length s)]
    (loop [i 0, out (transient [])]
      (if (< i n)
        (let [w (Character/charCount (.codePointAt s i))]
          (recur (+ i w) (conj! out (.substring s i (+ i w)))))
        (persistent! out)))))

(defn compare-strings
  "Compare two strings by code point; returns a negative, zero or positive int."
  ^long [^String a ^String b]
  (let [la (.length a) lb (.length b)]
    (loop [i 0 j 0]
      (cond
        (and (== i la) (== j lb)) 0
        (== i la) -1
        (== j lb) 1
        :else
        (let [ca (.codePointAt a i) cb (.codePointAt b j)]
          (if (== ca cb)
            (recur (+ i (Character/charCount ca)) (+ j (Character/charCount cb)))
            (if (< ca cb) -1 1)))))))

;; ---------------------------------------------------------------------------
;; Truthiness and sequence view

(defn truthy?
  "Template truthiness. Testing the undefined value is an `undefined` error."
  [v]
  (cond
    (nil? v) false
    (instance? Boolean v) (.booleanValue ^Boolean v)
    (instance? Long v) (not (== 0 (long v)))
    (instance? Double v) (not (== 0.0 (double v)))
    (string? v) (not (.isEmpty ^String v))
    (vector? v) (pos? (count v))
    (dict? v) (not (.isEmpty ^LinkedHashMap v))
    (undefined? v) (err/fail :undefined "truthiness of undefined value")
    :else true))

(defn sequence-view
  "The sequence view of `v` as a vector: a list is itself, a dict is its keys,
  a string is its characters. Anything else is a `type` error."
  [v]
  (cond
    (vector? v) v
    (dict? v) (vec (.keySet ^LinkedHashMap v))
    (string? v) (string-chars v)
    (undefined? v) (err/fail :undefined "undefined value used as a sequence")
    :else (err/fail :type "value is not a sequence")))

;; ---------------------------------------------------------------------------
;; Printing

(defn format-float
  "Shortest round-trip decimal form of a double, laid out like Python's repr."
  ^String [^double d]
  (cond
    (Double/isNaN d) "nan"
    (Double/isInfinite d) (if (pos? d) "inf" "-inf")
    (== d 0.0) (if (neg? (Math/copySign 1.0 d)) "-0.0" "0.0")
    :else
    (let [negative? (neg? d)
          bd   (.stripTrailingZeros (BigDecimal. (Double/toString (Math/abs d))))
          ds   (str (.unscaledValue bd))
          n    (count ds)
          e    (- n (.scale bd) 1)
          sb   (StringBuilder.)]
      (when negative? (.append sb \-))
      (cond
        (and (<= -4 e) (< e 16))
        (if (>= e 0)
          (do (if (> n (inc e))
                (.append sb (subs ds 0 (inc e)))
                (do (.append sb ds)
                    (dotimes [_ (- (inc e) n)] (.append sb \0))))
              (.append sb \.)
              (.append sb (if (> n (inc e)) (subs ds (inc e)) "0")))
          (do (.append sb "0.")
              (dotimes [_ (- (- e) 1)] (.append sb \0))
              (.append sb ds)))
        :else
        (do (.append sb (.charAt ds 0))
            (when (> n 1) (.append sb \.) (.append sb (subs ds 1)))
            (.append sb \e)
            (.append sb (if (neg? e) \- \+))
            (let [a (Math/abs (long e))]
              (when (< a 10) (.append sb \0))
              (.append sb a))))
      (.toString sb))))

(defn- write-repr-string! [^StringBuilder sb ^String s]
  (let [q (if (and (>= (.indexOf s "'") 0) (< (.indexOf s "\"") 0)) \" \')]
    (.append sb q)
    (dotimes [i (.length s)]
      (let [c (.charAt s i)]
        (cond
          (= c \\) (.append sb "\\\\")
          (= c \newline) (.append sb "\\n")
          (= c \return) (.append sb "\\r")
          (= c \tab) (.append sb "\\t")
          (and (= c \') (= q \')) (.append sb "\\'")
          :else (.append sb c))))
    (.append sb q)))

(declare write-str!)

(defn- write-repr! [^StringBuilder sb v]
  (if (string? v) (write-repr-string! sb v) (write-str! sb v)))

(defn write-str!
  "Append the string form of `v` (as printed by `{{ }}`) to `sb`."
  [^StringBuilder sb v]
  (cond
    (string? v) (.append sb ^String v)
    (instance? Long v) (.append sb (long v))
    (nil? v) (.append sb "None")
    (instance? Boolean v) (.append sb (if (.booleanValue ^Boolean v) "True" "False"))
    (instance? Double v) (.append sb (format-float v))
    (vector? v) (do (.append sb \[)
                    (let [n (count v)]
                      (dotimes [i n]
                        (when (pos? i) (.append sb ", "))
                        (write-repr! sb (nth v i))))
                    (.append sb \]))
    (dict? v) (do (.append sb \{)
                  (let [first? (volatile! true)]
                    (doseq [^java.util.Map$Entry e (.entrySet ^LinkedHashMap v)]
                      (if @first? (vreset! first? false) (.append sb ", "))
                      (write-repr-string! sb (.getKey e))
                      (.append sb ": ")
                      (write-repr! sb (.getValue e))))
                  (.append sb \}))
    (undefined? v) (err/fail :undefined "printing an undefined value")
    :else (.append sb "<macro>"))
  sb)

(defn to-str
  "The string form of `v`, as used by printing, `~` and the string filters."
  ^String [v]
  (if (string? v)
    v
    (.toString ^StringBuilder (write-str! (StringBuilder.) v))))

;; ---------------------------------------------------------------------------
;; Equality and ordering

(defn compare-numbers
  "Three-way comparison of two numbers (booleans count as integers)."
  ^long [a b]
  (let [a (->num a) b (->num b)]
    (if (and (instance? Long a) (instance? Long b))
      (Long/compare (long a) (long b))
      (let [x (double a) y (double b)]
        (cond (< x y) -1 (> x y) 1 :else 0)))))

(defn values-equal?
  "Template `==`. Undefined operands are an `undefined` error."
  [a b]
  (cond
    (or (undefined? a) (undefined? b)) (err/fail :undefined "comparison with undefined value")
    (number-value? a) (and (number-value? b) (zero? (compare-numbers a b)))
    (string? a) (and (string? b) (.equals ^String a b))
    (nil? a) (nil? b)
    (vector? a) (and (vector? b)
                     (== (count a) (count b))
                     (loop [i 0]
                       (or (== i (count a))
                           (and (values-equal? (nth a i) (nth b i)) (recur (inc i))))))
    (dict? a) (and (dict? b)
                   (let [^LinkedHashMap a a ^LinkedHashMap b b]
                     (and (== (.size a) (.size b))
                          (every? (fn [^java.util.Map$Entry e]
                                    (and (.containsKey b (.getKey e))
                                         (values-equal? (.getValue e) (.get b (.getKey e)))))
                                  (.entrySet a)))))
    :else (identical? a b)))

;; ---------------------------------------------------------------------------
;; Conversion from ordinary Clojure data

(defn from-clj
  "Convert Clojure data to template values: maps become dicts (keyword keys are
  turned into their names), sequential collections and sets become lists,
  integers become `Long`s, other numbers `Double`s. Dicts built by this
  library pass through unchanged."
  [x]
  (cond
    (or (nil? x) (string? x) (instance? Boolean x) (instance? Long x)
        (instance? Double x) (undefined? x) (dict? x) (instance? Macro x)) x
    (keyword? x) (name x)
    (symbol? x) (name x)
    (integer? x) (long x)
    (number? x) (double x)
    (map? x) (let [m (LinkedHashMap.)]
               (doseq [[k v] x] (.put m (if (or (keyword? k) (symbol? k)) (name k) (str k)) (from-clj v)))
               m)
    (or (sequential? x) (set? x)) (mapv from-clj x)
    :else (throw (IllegalArgumentException. (str "unsupported context value: " (class x))))))
