(ns kvstore.value
  "The Tessera document value model.

  Values are plain Clojure data:

  | Tessera | Clojure                                 |
  |---------|-----------------------------------------|
  | null    | `nil`                                   |
  | bool    | `true` / `false`                        |
  | int     | `long` (signed 64-bit)                  |
  | string  | `String`                                |
  | list    | vector (any sequential is accepted)     |
  | object  | map with `String` keys                  |

  This namespace provides the binary serialisation (spec section 4.2), the
  canonical one-line rendering (4.4/4.5), depth, ordering helpers and the
  field-path operations."
  (:require [kvstore.bytes :as b]
            [kvstore.limits :as lim])
  (:import (java.io ByteArrayOutputStream)))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Classification

(defn type-rank
  "Type rank of a value: null 0, bool 1, int 2, string 3, list 4, object 5."
  ^long [v]
  (cond
    (nil? v) 0
    (boolean? v) 1
    (integer? v) 2
    (string? v) 3
    (map? v) 5
    (sequential? v) 4
    :else (throw (IllegalArgumentException. (str "not a Tessera value: " (pr-str v))))))

(defn container? [v] (or (map? v) (sequential? v)))

(defn depth
  "Nesting depth: 1 for scalars and empty containers, else 1 + deepest child."
  ^long [v]
  (cond
    (map? v) (inc (long (reduce max 0 (map depth (vals v)))))
    (sequential? v) (inc (long (reduce max 0 (map depth v))))
    :else 1))

(defn sorted-fields
  "Fields of an object as `[name-bytes name value]` triples in ascending
  byte-wise order of the UTF-8 of the names."
  [m]
  (let [triples (mapv (fn [[k v]] [(b/utf8 k) k v]) m)]
    (vec (sort (fn [x y] (b/compare-bytes (x 0) (y 0))) triples))))

;; ---------------------------------------------------------------------------
;; Serialisation

(declare write-value!)

(defn- write-u32! [^ByteArrayOutputStream out ^long n]
  (.write out (int (bit-and 0xFF (unsigned-bit-shift-right n 24))))
  (.write out (int (bit-and 0xFF (unsigned-bit-shift-right n 16))))
  (.write out (int (bit-and 0xFF (unsigned-bit-shift-right n 8))))
  (.write out (int (bit-and 0xFF n))))

(defn- write-value! [^ByteArrayOutputStream out v]
  (cond
    (nil? v) (.write out 0)
    (false? v) (.write out 1)
    (true? v) (.write out 2)
    (integer? v) (let [n (long v)]
                   (.write out 3)
                   (write-u32! out (unsigned-bit-shift-right n 32))
                   (write-u32! out n))
    (string? v) (let [bs (b/utf8 v)]
                  (.write out 4)
                  (write-u32! out (alength bs))
                  (.write out bs 0 (alength bs)))
    (map? v) (do (.write out 6)
                 (write-u32! out (count v))
                 (doseq [[^bytes nb _ x] (sorted-fields v)]
                   (write-u32! out (alength nb))
                   (.write out nb 0 (alength nb))
                   (write-value! out x)))
    (sequential? v) (do (.write out 5)
                        (write-u32! out (count v))
                        (doseq [x v] (write-value! out x)))
    :else (throw (IllegalArgumentException. (str "not a Tessera value: " (pr-str v))))))

(defn ser
  "Serialise a value to its stored byte form."
  ^bytes [v]
  (let [out (ByteArrayOutputStream. 64)]
    (write-value! out v)
    (.toByteArray out)))

(declare read-value)

(defn- read-value
  "Read one value from `buf` at `pos` (an int-array of length 1 used as a
  cursor)."
  [^bytes buf ^ints pos]
  (let [p (aget pos 0)
        tag (b/u8 buf p)]
    (case (int tag)
      0 (do (aset pos 0 (inc p)) nil)
      1 (do (aset pos 0 (inc p)) false)
      2 (do (aset pos 0 (inc p)) true)
      3 (do (aset pos 0 (+ p 9)) (b/u64 buf (inc p)))
      4 (let [n (b/u32 buf (inc p)) s (+ p 5)]
          (aset pos 0 (int (+ s n)))
          (String. buf (int s) (int n) java.nio.charset.StandardCharsets/UTF_8))
      5 (let [n (b/u32 buf (inc p))]
          (aset pos 0 (+ p 5))
          (loop [i 0 acc (transient [])]
            (if (< i n)
              (recur (inc i) (conj! acc (read-value buf pos)))
              (persistent! acc))))
      6 (let [n (b/u32 buf (inc p))]
          (aset pos 0 (+ p 5))
          (loop [i 0 acc (transient {})]
            (if (< i n)
              (let [q (aget pos 0)
                    kl (b/u32 buf q)
                    k (String. buf (int (+ q 4)) (int kl) java.nio.charset.StandardCharsets/UTF_8)]
                (aset pos 0 (int (+ q 4 kl)))
                (recur (inc i) (assoc! acc k (read-value buf pos))))
              (persistent! acc)))))))

(defn deser
  "Inverse of `ser`."
  [^bytes buf]
  (read-value buf (int-array 1)))

;; ---------------------------------------------------------------------------
;; Rendering

(defn- hex4 [^long c]
  (let [s (Integer/toHexString (int c))]
    (str (subs "0000" (count s)) s)))

(defn render-string-to!
  "Append the quoted, escaped form of string `s` to StringBuilder `sb`."
  [^StringBuilder sb ^String s]
  (.append sb \")
  (let [n (.length s)]
    (loop [i 0]
      (when (< i n)
        (let [c (.charAt s i)]
          (case c
            \" (.append sb "\\\"")
            \\ (.append sb "\\\\")
            \backspace (.append sb "\\b")
            \tab (.append sb "\\t")
            \newline (.append sb "\\n")
            \formfeed (.append sb "\\f")
            \return (.append sb "\\r")
            (if (or (< (int c) 0x20) (== (int c) 0x7f))
              (.append sb (str "\\u" (hex4 (int c))))
              (.append sb c))))
        (recur (inc i)))))
  (.append sb \"))

(defn render-string
  "Quoted, escaped rendering of a string."
  ^String [^String s]
  (let [sb (StringBuilder.)]
    (render-string-to! sb s)
    (.toString sb)))

(defn render-to!
  "Append the canonical one-line rendering of `v` to `sb`."
  [^StringBuilder sb v]
  (cond
    (nil? v) (.append sb "null")
    (boolean? v) (.append sb (if v "true" "false"))
    (integer? v) (.append sb (long v))
    (string? v) (render-string-to! sb v)
    (map? v) (do (.append sb \{)
                 (loop [fs (seq (sorted-fields v)) first? true]
                   (when fs
                     (let [[_ k x] (first fs)]
                       (when-not first? (.append sb \,))
                       (render-string-to! sb k)
                       (.append sb \:)
                       (render-to! sb x)
                       (recur (next fs) false))))
                 (.append sb \}))
    (sequential? v) (do (.append sb \[)
                        (loop [xs (seq v) first? true]
                          (when xs
                            (when-not first? (.append sb \,))
                            (render-to! sb (first xs))
                            (recur (next xs) false)))
                        (.append sb \]))
    :else (throw (IllegalArgumentException. (str "not a Tessera value: " (pr-str v)))))
  sb)

(defn render
  "Canonical one-line text of a value."
  ^String [v]
  (.toString ^StringBuilder (render-to! (StringBuilder.) v)))

;; ---------------------------------------------------------------------------
;; Comparison

(defn compare-strings
  "Byte-wise (UTF-8) comparison of two strings."
  ^long [^String x ^String y]
  (b/compare-bytes (b/utf8 x) (b/utf8 y)))

(defn same-rank-compare
  "Order two scalar values of the same type rank: negative, zero, positive.
  `nil` for lists and objects, which are unordered."
  [x y]
  (case (type-rank x)
    0 0
    1 (compare x y)
    2 (compare (long x) (long y))
    3 (compare-strings x y)
    nil))

;; ---------------------------------------------------------------------------
;; Paths.  A path is a vector of segment strings.

(def missing
  "Sentinel returned by `resolve-path` when the path leads nowhere."
  ::missing)

(defn resolve-path
  "Value at `segments` inside `doc`, or `missing`.  Only objects are
  traversed; lists never are."
  [doc segments]
  (loop [v doc segs (seq segments)]
    (if segs
      (if (and (map? v) (contains? v (first segs)))
        (recur (get v (first segs)) (next segs))
        missing)
      v)))

(defn assoc-path
  "Set the field at `segments` to `x`, creating empty objects for missing
  intermediate segments.  Throws `ex-info` with kind `:not-object` when a
  value on the way is present but not an object."
  [doc segments x]
  (when-not (map? doc)
    (throw (ex-info "not an object" {:kind :not-object})))
  (let [[s & more] segments]
    (if (empty? more)
      (assoc doc s x)
      (assoc doc s (assoc-path (get doc s {}) more x)))))

(defn dissoc-path
  "Remove the field at `segments`.  Throws kind `:not-object` when a value on
  the way is not an object and `:no-field` when a field is absent."
  [doc segments]
  (when-not (map? doc)
    (throw (ex-info "not an object" {:kind :not-object})))
  (let [[s & more] segments]
    (when-not (contains? doc s)
      (throw (ex-info "no such field" {:kind :no-field})))
    (if (empty? more)
      (dissoc doc s)
      (assoc doc s (dissoc-path (get doc s) more)))))

(defn check-document!
  "Throw `:depth` or `:doc-too-large` when `doc` breaks the limits; return the
  serialised bytes otherwise."
  ^bytes [doc]
  (when (> (depth doc) lim/max-depth)
    (throw (ex-info "document too deep" {:kind :depth})))
  (let [bs (ser doc)]
    (when (> (alength bs) lim/max-doc)
      (throw (ex-info "document too large" {:kind :doc-too-large})))
    bs))
