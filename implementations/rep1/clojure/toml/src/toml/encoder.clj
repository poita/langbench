(ns toml.encoder
  "Canonical TOML output for tagged trees.

  Within a table, plain key/value pairs come first in key order, then each
  sub-table or array of tables follows under its own header, also in key
  order.  Arrays that are not non-empty arrays of tables, and every table
  below a plain value, are written inline.  Every table gets a header, the
  root excepted."
  (:require [toml.data :as d]
            [toml.util :as u])
  (:import (java.lang StringBuilder)))

(set! *warn-on-reflection* true)

(defn- bare-key? [^String k]
  (and (pos? (.length k))
       (every? (fn [ch] (let [c (int ch)]
                          (or (<= 97 c 122) (<= 65 c 90) (<= 48 c 57) (== c 95) (== c 45))))
               k)))

(defn- append-string! [^StringBuilder sb ^String s]
  (.append sb \")
  (dotimes [i (.length s)]
    (let [ch (.charAt s i) c (int ch)]
      (cond (== c 34) (.append sb "\\\"")
            (== c 92) (.append sb "\\\\")
            (== c 8) (.append sb "\\b")
            (== c 9) (.append sb "\\t")
            (== c 10) (.append sb "\\n")
            (== c 12) (.append sb "\\f")
            (== c 13) (.append sb "\\r")
            (or (< c 32) (== c 127))
            (do (.append sb "\\u00")
                (.append sb (Character/forDigit (bit-shift-right c 4) 16))
                (.append sb (Character/forDigit (bit-and c 15) 16)))
            :else (.append sb ch))))
  (.append sb \"))

(defn- append-key! [^StringBuilder sb ^String k]
  (if (bare-key? k) (.append sb k) (append-string! sb k)))

(defn- append-inline! [^StringBuilder sb node]
  (cond
    (d/scalar? node)
    (if (= :string (:type node))
      (append-string! sb (:value node))
      (.append sb ^String (:value node)))

    (map? node)
    (let [ks (u/sorted-keys node)]
      (.append sb \{)
      (dotimes [i (alength ks)]
        (when (pos? i) (.append sb ", "))
        (let [k (aget ks i)]
          (append-key! sb k)
          (.append sb " = ")
          (append-inline! sb (get node k))))
      (.append sb \}))

    :else
    (do (.append sb \[)
        (loop [s (seq node) first? true]
          (when s
            (when-not first? (.append sb ", "))
            (append-inline! sb (first s))
            (recur (next s) false)))
        (.append sb \]))))

(defn- array-of-tables? [v]
  (and (sequential? v) (seq v) (every? d/table? v)))

(declare append-table!)

(defn- append-header! [^StringBuilder sb ^String path open close]
  (when (pos? (.length sb)) (.append sb \newline))
  (.append sb ^String open)
  (.append sb path)
  (.append sb ^String close)
  (.append sb \newline))

(defn- append-table!
  "Writes the body of `table`, then its sub-tables.  `path` is the rendered
  dotted path of the table (empty for the root)."
  [^StringBuilder sb table ^String path]
  (let [ks (u/sorted-keys table)]
    (doseq [k ks]
      (let [v (get table k)]
        (when-not (or (d/table? v) (array-of-tables? v))
          (append-key! sb k)
          (.append sb " = ")
          (append-inline! sb v)
          (.append sb \newline))))
    (doseq [k ks]
      (let [v (get table k)
            sub (str (when-not (.isEmpty path) (str path ".")) (let [b (StringBuilder.)] (append-key! b k) (.toString b)))]
        (cond
          (d/table? v)
          (do (append-header! sb sub "[" "]")
              (append-table! sb v sub))

          (array-of-tables? v)
          (doseq [el v]
            (append-header! sb sub "[[" "]]")
            (append-table! sb el sub)))))))

(defn encode
  "Returns the canonical TOML text of the tagged tree `tree` (whose root must
  be a table)."
  ^String [tree]
  (let [sb (StringBuilder.)]
    (append-table! sb tree "")
    (when (zero? (.length sb)) (.append sb \newline))
    (.toString sb)))
