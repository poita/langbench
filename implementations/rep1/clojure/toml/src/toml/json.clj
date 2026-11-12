(ns toml.json
  "Reading and writing tagged trees as JSON, the interchange format of the
  `toml-test` suite.

  A scalar is a JSON object `{\"type\": ..., \"value\": ...}` whose two members
  are strings; a table is any other JSON object; an array is a JSON array.
  The writer is compact and sorts object members by code point."
  (:require [toml.data :as d]
            [toml.util :as u])
  (:import (java.lang StringBuilder)))

(set! *warn-on-reflection* true)

;; ----------------------------------------------------------------- writer

(defn- hex4 [^StringBuilder sb ^long c]
  (.append sb "\\u00")
  (.append sb (Character/forDigit (bit-shift-right c 4) 16))
  (.append sb (Character/forDigit (bit-and c 15) 16)))

(defn- write-string [^StringBuilder sb ^String s]
  (.append sb \")
  (dotimes [i (.length s)]
    (let [ch (.charAt s i) c (long (int ch))]
      (cond (== c 34) (.append sb "\\\"")
            (== c 92) (.append sb "\\\\")
            (== c 8) (.append sb "\\b")
            (== c 12) (.append sb "\\f")
            (== c 10) (.append sb "\\n")
            (== c 13) (.append sb "\\r")
            (== c 9) (.append sb "\\t")
            (< c 32) (hex4 sb c)
            :else (.append sb ch))))
  (.append sb \"))

(defn- write-node [^StringBuilder sb node]
  (cond
    (d/scalar? node)
    (do (.append sb "{\"type\":")
        (write-string sb (name (:type node)))
        (.append sb ",\"value\":")
        (write-string sb (:value node))
        (.append sb \}))

    (map? node)
    (let [ks (u/sorted-keys node)]
      (.append sb \{)
      (dotimes [i (alength ks)]
        (when (pos? i) (.append sb \,))
        (let [k (aget ks i)]
          (write-string sb k)
          (.append sb \:)
          (write-node sb (get node k))))
      (.append sb \}))

    :else
    (do (.append sb \[)
        (loop [s (seq node) first? true]
          (when s
            (when-not first? (.append sb \,))
            (write-node sb (first s))
            (recur (next s) false)))
        (.append sb \]))))

(defn write-tagged
  "Returns the compact, key-sorted JSON text of the tagged tree `tree`."
  ^String [tree]
  (let [sb (StringBuilder.)]
    (write-node sb tree)
    (.toString sb)))

;; ----------------------------------------------------------------- reader

(defn- jfail [^String msg pos]
  (throw (ex-info (str "JSON error: " msg " at offset " pos) {:json/error true :pos pos})))

;; The reader is a set of functions that take the text and an index and
;; return `[value next-index]`.

(defn- skip-ws ^long [^String s ^long i]
  (loop [i i]
    (if (< i (.length s))
      (let [c (.charAt s i)]
        (if (or (= c \space) (= c \newline) (= c \return) (= c \tab))
          (recur (unchecked-inc i))
          i))
      i)))

(declare read-value)

(defn- hex-digit ^long [^String s ^long i]
  (let [v (if (< i (.length s)) (Character/digit (.charAt s i) 16) -1)]
    (when (neg? v) (jfail "bad \\u escape" i))
    v))

(defn- read-string-at
  "Reads the JSON string whose opening quote is at `i`; returns [string end]."
  [^String s ^long i]
  (let [sb (StringBuilder.)]
    (loop [j (inc i)]
      (when (>= j (.length s)) (jfail "unterminated string" i))
      (let [c (.charAt s j)]
        (cond
          (= c \") [(.toString sb) (inc j)]
          (= c \\)
          (let [e (.charAt s (inc j))]
            (case e
              \" (do (.append sb \") (recur (+ j 2)))
              \\ (do (.append sb \\) (recur (+ j 2)))
              \/ (do (.append sb \/) (recur (+ j 2)))
              \b (do (.append sb (char 8)) (recur (+ j 2)))
              \f (do (.append sb (char 12)) (recur (+ j 2)))
              \n (do (.append sb \newline) (recur (+ j 2)))
              \r (do (.append sb \return) (recur (+ j 2)))
              \t (do (.append sb \tab) (recur (+ j 2)))
              \u (let [v (+ (* 4096 (hex-digit s (+ j 2))) (* 256 (hex-digit s (+ j 3)))
                           (* 16 (hex-digit s (+ j 4))) (hex-digit s (+ j 5)))]
                   (.append sb (char v))
                   (recur (+ j 6)))
              (jfail "bad escape" j)))
          :else (do (.append sb c) (recur (inc j))))))))

(defn- finish-object [m]
  (let [t (get m "type") v (get m "value")]
    (if (and (== (count m) 2) (string? t) (string? v)
             (contains? d/scalar-types (keyword t)))
      (d/scalar (keyword t) v)
      m)))

(defn- read-object [^String s ^long i]
  (let [i (skip-ws s (inc i))]
    (if (= (.charAt s i) \})
      [{} (inc i)]
      (loop [i i m (transient {})]
        (let [[k j] (read-string-at s (skip-ws s i))
              j (skip-ws s j)
              _ (when-not (= (.charAt s j) \:) (jfail "expected ':'" j))
              [v j] (read-value s (inc j))
              m (assoc! m k v)
              j (skip-ws s j)
              c (.charAt s j)]
          (cond (= c \,) (recur (inc j) m)
                (= c \}) [(finish-object (persistent! m)) (inc j)]
                :else (jfail "expected ',' or '}'" j)))))))

(defn- read-array [^String s ^long i]
  (let [i (skip-ws s (inc i))]
    (if (= (.charAt s i) \])
      [[] (inc i)]
      (loop [i i out (transient [])]
        (let [[v j] (read-value s i)
              out (conj! out v)
              j (skip-ws s j)
              c (.charAt s j)]
          (cond (= c \,) (recur (inc j) out)
                (= c \]) [(persistent! out) (inc j)]
                :else (jfail "expected ',' or ']'" j)))))))

(defn- read-value [^String s ^long i]
  (let [i (skip-ws s i)
        c (.charAt s i)]
    (cond (= c \{) (read-object s i)
          (= c \[) (read-array s i)
          (= c \") (read-string-at s i)
          :else (jfail "unsupported JSON value" i))))

(defn read-tagged
  "Parses the JSON text `text` into a tagged tree."
  [^String text]
  (first (read-value text 0)))
