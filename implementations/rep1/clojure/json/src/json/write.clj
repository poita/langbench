(ns json.write
  "Canonical serialization of a JSON tree (see [[json.tree]]).

  The output has no insignificant whitespace; object members are sorted by key
  in UTF-16 code unit order with duplicate keys collapsed to the last
  occurrence; strings escape only what must be escaped; numbers are emitted as
  their stored text. The whole document is appended to a single
  `StringBuilder` (no per-subtree strings), so writing is linear in the output
  size apart from sorting object keys."
  (:require [json.tree :as tree])
  (:import (java.nio.charset StandardCharsets)
           (java.util Arrays Comparator)
           (json.tree Num Obj)))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(def ^:private hex "0123456789abcdef")

(defn- write-string!
  [^StringBuilder sb ^String s]
  (let [n (.length s)]
    (.append sb \")
    (loop [i 0 run 0]
      (if (< i n)
        (let [c (long (int (.charAt s i)))]
          (if (or (< c 0x20) (== c 0x22) (== c 0x5C))
            (do (.append sb s (int run) (int i))
                (case c
                  0x22 (.append sb "\\\"")
                  0x5C (.append sb "\\\\")
                  8    (.append sb "\\b")
                  12   (.append sb "\\f")
                  10   (.append sb "\\n")
                  13   (.append sb "\\r")
                  9    (.append sb "\\t")
                  (do (.append sb "\\u00")
                      (.append sb (.charAt ^String hex (bit-shift-right c 4)))
                      (.append sb (.charAt ^String hex (bit-and c 15)))))
                (recur (inc i) (inc i)))
            (recur (inc i) run)))
        (.append sb s (int run) (int n))))
    (.append sb \")))

(def ^:private ^Comparator by-key
  "Orders `[key value]` members by key in UTF-16 code unit order, which is
  exactly how `String.compareTo` compares."
  (reify Comparator
    (compare [_ a b]
      (.compareTo ^String (key a) ^String (key b)))))

(declare write-value!)

(defn- write-object!
  [^StringBuilder sb ^Obj o]
  (let [arr (to-array (tree/members o))
        n   (alength arr)]
    ;; Arrays/sort on objects is a stable merge sort, so equal keys stay in
    ;; input order and the last of each run is the last occurrence.
    (when (> n 1) (Arrays/sort arr by-key))
    (.append sb \{)
    (loop [i 0 first? true]
      (when (< i n)
        (let [e (aget arr i)
              k ^String (key e)]
          (if (and (< (inc i) n) (.equals k (key (aget arr (inc i)))))
            (recur (inc i) first?)
            (do (when-not first? (.append sb \,))
                (write-string! sb k)
                (.append sb \:)
                (write-value! sb (val e))
                (recur (inc i) false))))))
    (.append sb \})))

(defn- write-array!
  [^StringBuilder sb v]
  (.append sb \[)
  (loop [s (seq v) first? true]
    (when s
      (when-not first? (.append sb \,))
      (write-value! sb (first s))
      (recur (next s) false)))
  (.append sb \]))

(defn- write-value!
  [^StringBuilder sb v]
  (cond
    (nil? v)              (.append sb "null")
    (identical? v true)   (.append sb "true")
    (identical? v false)  (.append sb "false")
    (string? v)           (write-string! sb v)
    (instance? Num v)     (.append sb (tree/number-text v))
    (instance? Obj v)     (write-object! sb v)
    (sequential? v)       (write-array! sb v)
    :else (throw (IllegalArgumentException.
                  (str "not a JSON tree value: " (pr-str v))))))

(defn write-string
  "Serializes `tree` to a canonical JSON string."
  ^String [tree]
  (let [sb (StringBuilder.)]
    (write-value! sb tree)
    (.toString sb)))

(defn write-bytes
  "Serializes `tree` to canonical JSON, encoded as UTF-8 bytes."
  ^bytes [tree]
  (.getBytes (write-string tree) StandardCharsets/UTF_8))
