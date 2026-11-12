(ns sqlitefile.value
  "SQLite values: ordering, type affinity and text formatting (SPEC Parts 3
  and 5).

  A value is `nil` (NULL), a `Long` (INTEGER), a `Double` (REAL), a `String`
  (TEXT) or a `byte[]` (BLOB)."
  (:require [clojure.string :as str])
  (:import (java.math BigDecimal MathContext RoundingMode)))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Ordering

(defn- class-rank ^long [v]
  (cond (nil? v) 0
        (number? v) 1
        (string? v) 2
        :else 3))

(defn- cmp-text ^long [^String a ^String b]
  ;; UTF-8 byte order equals code point order (not UTF-16 unit order).
  (let [la (.length a) lb (.length b)]
    (loop [i 0 j 0]
      (cond
        (and (>= i la) (>= j lb)) 0
        (>= i la) -1
        (>= j lb) 1
        :else
        (let [ca (.codePointAt a i) cb (.codePointAt b j)]
          (cond (< ca cb) -1
                (> ca cb) 1
                :else (recur (+ i (Character/charCount ca))
                             (+ j (Character/charCount cb)))))))))

(defn- cmp-blob ^long [^bytes a ^bytes b]
  (let [la (alength a) lb (alength b) n (min la lb)]
    (loop [i 0]
      (if (< i n)
        (let [x (bit-and 0xff (long (aget a i))) y (bit-and 0xff (long (aget b i)))]
          (cond (< x y) -1
                (> x y) 1
                :else (recur (inc i))))
        (cond (< la lb) -1 (> la lb) 1 :else 0)))))

(defn- cmp-num ^long [a b]
  (if (and (instance? Long a) (instance? Long b))
    (long (Long/compare (long a) (long b)))
    (let [x (double a) y (double b)]
      (cond (< x y) -1 (> x y) 1 :else 0))))

(defn compare-values
  "Three-way comparison (-1, 0 or 1) of two values by SQLite's ordering:
  NULL < numbers < TEXT < BLOB; numbers by value, TEXT and BLOB bytewise."
  ^long [a b]
  (let [ra (class-rank a) rb (class-rank b)]
    (cond
      (< ra rb) -1
      (> ra rb) 1
      :else (case (int ra)
              0 0
              1 (cmp-num a b)
              2 (cmp-text a b)
              3 (cmp-blob a b)))))

;; ---------------------------------------------------------------------------
;; Formatting

(defn- format-real [^double d]
  (if (zero? d)
    "0.0"
    (let [bd (.round (BigDecimal. d) (MathContext. 15 RoundingMode/HALF_EVEN))
          negative? (neg? (.signum bd))
          digits (-> (.unscaledValue bd) .abs str (str/replace #"0+$" ""))
          e10 (- (.precision bd) (.scale bd) 1)
          body (if (or (< e10 -4) (>= e10 15))
                 (str (subs digits 0 1) "."
                      (if (> (count digits) 1) (subs digits 1) "0")
                      "e" (if (neg? e10) "-" "+")
                      (let [a (Math/abs (long e10))] (if (< a 10) (str "0" a) (str a))))
                 (if (>= e10 0)
                   (let [n (inc e10)
                         padded (if (< (count digits) n)
                                  (str digits (apply str (repeat (- n (count digits)) \0)))
                                  digits)
                         frac (subs padded n)]
                     (str (subs padded 0 n) "." (if (empty? frac) "0" frac)))
                   (str "0." (apply str (repeat (- (- e10) 1) \0)) digits)))]
      (if negative? (str "-" body) body))))

(defn hex
  "Uppercase hexadecimal encoding of a byte array."
  [^bytes bs]
  (let [sb (StringBuilder. (* 2 (alength bs)))]
    (dotimes [i (alength bs)]
      (let [x (bit-and 0xff (long (aget bs i)))]
        (.append sb (.charAt "0123456789ABCDEF" (bit-shift-right x 4)))
        (.append sb (.charAt "0123456789ABCDEF" (bit-and x 15)))))
    (str sb)))

(defn format-value
  "Render a value the way the `sqlite3` shell does in list mode with
  `-nullvalue NULL` and hex-encoded blobs."
  [v]
  (cond
    (nil? v) "NULL"
    (instance? Long v) (Long/toString (long v))
    (instance? Double v) (format-real v)
    (string? v) v
    :else (hex v)))

;; ---------------------------------------------------------------------------
;; Affinity

(defn affinity
  "Column affinity (`:integer`, `:text`, `:blob`, `:real` or `:numeric`) for a
  declared type string, using SQLite's rules in order."
  [declared-type]
  (let [t (str/upper-case (or declared-type ""))
        has? (fn [s] (str/includes? t s))]
    (cond
      (has? "INT") :integer
      (or (has? "CHAR") (has? "CLOB") (has? "TEXT")) :text
      (or (has? "BLOB") (str/blank? t)) :blob
      (or (has? "REAL") (has? "FLOA") (has? "DOUB")) :real
      :else :numeric)))

(def ^:private numeric-constant
  #"[ \t]*([+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)[ \t]*")

(defn parse-numeric-text
  "If `s` is entirely a numeric constant (spaces and tabs allowed around it)
  return it as a `Long` (no `.`/exponent and fits in 64 bits) or `Double`;
  otherwise nil."
  [^String s]
  (when-let [[_ num] (re-matches numeric-constant s)]
    (or (when-not (re-find #"[.eE]" num)
          (try (Long/parseLong num) (catch NumberFormatException _ nil)))
        (Double/parseDouble num))))

(defn apply-affinity
  "Convert a query literal according to a column's affinity before
  comparison (SPEC Part 3)."
  [aff literal]
  (case aff
    :text (if (number? literal) (format-value literal) literal)
    (:integer :real :numeric) (if (string? literal)
                                (or (parse-numeric-text literal) literal)
                                literal)
    literal))
