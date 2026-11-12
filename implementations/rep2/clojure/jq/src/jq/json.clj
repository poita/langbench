(ns jq.json
  "A hand-written JSON (RFC 8259) reader and a compact writer for jq values.

  See [[jq.value]] for how JSON values are represented."
  (:require [jq.value :as v])
  (:import (java.math BigDecimal)
           (java.util LinkedHashMap)))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Reading

(defn- parse-error [^String s ^long i msg]
  (throw (ex-info (str "JSON parse error at offset " i ": " msg)
                  {:type ::parse-error :offset i})))

(defn- skip-ws ^long [^String s ^long i]
  (let [n (.length s)]
    (loop [i i]
      (if (< i n)
        (let [c (int (.charAt s i))]
          (if (or (== c 32) (== c 10) (== c 13) (== c 9)) (recur (inc i)) i))
        i))))

(defn- hex4 ^long [^String s ^long i]
  (when (> (+ i 4) (.length s)) (parse-error s i "truncated \\u escape"))
  (loop [j 0 acc 0]
    (if (< j 4)
      (let [d (Character/digit (.charAt s (+ i j)) 16)]
        (when (neg? d) (parse-error s (+ i j) "bad hex digit"))
        (recur (inc j) (+ (* acc 16) d)))
      acc)))

(defn- read-string-literal
  "Reads the string whose opening quote is at index `i`; returns
  `[string next-index]` packed into the `out` long-array slot (index)."
  [^String s ^long i ^longs out]
  (let [n (.length s)
        start (inc i)]
    ;; fast path: no escapes
    (loop [j start]
      (if (>= j n)
        (parse-error s i "unterminated string")
        (let [c (.charAt s j)]
          (cond
            (= c \") (do (aset out 0 (inc j)) (.substring s start j))
            (= c \\) (let [sb (StringBuilder.)]
                        (.append sb s start j)
                        (loop [j j]
                          (if (>= j n)
                            (parse-error s i "unterminated string")
                            (let [c (.charAt s j)]
                              (cond
                                (= c \") (do (aset out 0 (inc j)) (.toString sb))
                                (= c \\)
                                (let [e (if (< (inc j) n) (.charAt s (inc j)) (parse-error s j "bad escape"))]
                                  (case e
                                    \" (do (.append sb \") (recur (+ j 2)))
                                    \\ (do (.append sb \\) (recur (+ j 2)))
                                    \/ (do (.append sb \/) (recur (+ j 2)))
                                    \b (do (.append sb \backspace) (recur (+ j 2)))
                                    \f (do (.append sb \formfeed) (recur (+ j 2)))
                                    \n (do (.append sb \newline) (recur (+ j 2)))
                                    \r (do (.append sb \return) (recur (+ j 2)))
                                    \t (do (.append sb \tab) (recur (+ j 2)))
                                    \u (do (.append sb (char (hex4 s (+ j 2)))) (recur (+ j 6)))
                                    (parse-error s j "bad escape")))
                                :else (do (.append sb c) (recur (inc j))))))))
            :else (recur (inc j))))))))

(defn- number-char? [c]
  (let [c (int c)]
    (or (<= 48 c 57) (== c 45) (== c 43) (== c 46) (== c 101) (== c 69))))

(declare read-value)

(defn- read-array [^String s ^long i ^longs out]
  (let [i (skip-ws s (inc i))]
    (if (and (< i (.length s)) (= (.charAt s i) \]))
      (do (aset out 0 (inc i)) [])
      (loop [acc (transient []) i i]
        (let [x (read-value s i out)
              acc (conj! acc x)
              i (skip-ws s (aget out 0))]
          (when (>= i (.length s)) (parse-error s i "unterminated array"))
          (let [c (.charAt s i)]
            (cond (= c \,) (recur acc (skip-ws s (inc i)))
                  (= c \]) (do (aset out 0 (inc i)) (persistent! acc))
                  :else (parse-error s i "expected , or ]"))))))))

(defn- read-object [^String s ^long i ^longs out]
  (let [i (skip-ws s (inc i))
        m (LinkedHashMap.)]
    (if (and (< i (.length s)) (= (.charAt s i) \}))
      (do (aset out 0 (inc i)) (v/new-obj m))
      (loop [i i]
        (when-not (and (< i (.length s)) (= (.charAt s i) \"))
          (parse-error s i "expected string key"))
        (let [k (read-string-literal s i out)
              i (skip-ws s (aget out 0))]
          (when-not (and (< i (.length s)) (= (.charAt s i) \:))
            (parse-error s i "expected :"))
          (let [x (read-value s (skip-ws s (inc i)) out)
                i (skip-ws s (aget out 0))]
            (.put m k x)
            (when (>= i (.length s)) (parse-error s i "unterminated object"))
            (let [c (.charAt s i)]
              (cond (= c \,) (recur (skip-ws s (inc i)))
                    (= c \}) (do (aset out 0 (inc i)) (v/new-obj m))
                    :else (parse-error s i "expected , or }")))))))))

(defn- read-value [^String s ^long i ^longs out]
  (when (>= i (.length s)) (parse-error s i "unexpected end of input"))
  (let [c (.charAt s i)]
    (cond
      (= c \{) (read-object s i out)
      (= c \[) (read-array s i out)
      (= c \") (read-string-literal s i out)
      (= c \t) (if (.startsWith s "true" i) (do (aset out 0 (+ i 4)) true) (parse-error s i "bad literal"))
      (= c \f) (if (.startsWith s "false" i) (do (aset out 0 (+ i 5)) false) (parse-error s i "bad literal"))
      (= c \n) (if (.startsWith s "null" i) (do (aset out 0 (+ i 4)) nil) (parse-error s i "bad literal"))
      (or (= c \-) (<= 48 (int c) 57))
      (let [n (.length s)
            j (loop [j (inc i)] (if (and (< j n) (number-char? (.charAt s j))) (recur (inc j)) j))]
        (aset out 0 (long j))
        (try (Double/parseDouble (.substring s i j))
             (catch NumberFormatException _ (parse-error s i "bad number"))))
      :else (parse-error s i "unexpected character"))))

(defn parse
  "Parses the JSON text `s` (exactly one value, optionally surrounded by
  whitespace) into a jq value. Throws `ex-info` with `:type ::parse-error` on
  malformed input."
  [^String s]
  (let [out (long-array 1)
        x (read-value s (skip-ws s 0) out)
        i (skip-ws s (aget out 0))]
    (when (< i (.length s)) (parse-error s i "trailing characters"))
    x))

(def ^:private number-re #"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?")

(defn parse-number
  "Parses `s` as a complete JSON number literal; returns a double, or nil if
  `s` is not exactly a JSON number."
  [^String s]
  (when (re-matches number-re s)
    (Double/parseDouble s)))

;; ---------------------------------------------------------------------------
;; Writing

(defn format-number
  "The jq text of a double: integral values print as integers, other values in
  the shortest decimal form that round-trips."
  ^String [^double d]
  (cond
    (Double/isNaN d) "null"
    (Double/isInfinite d) (if (pos? d) "1.7976931348623157e+308" "-1.7976931348623157e+308")
    (and (== d (Math/rint d)) (< (Math/abs d) 1e17))
    (if (and (zero? d) (neg? (Math/copySign 1.0 d)))
      "-0"
      (Long/toString (long d)))
    :else (.toPlainString (.stripTrailingZeros (BigDecimal. (Double/toString d))))))

(def ^:private hex "0123456789abcdef")

(defn- write-string [^StringBuilder sb ^String s]
  (.append sb \")
  (let [n (.length s)]
    (loop [i 0 start 0]
      (if (< i n)
        (let [c (.charAt s i)
              code (int c)]
          (if (or (< code 32) (== code 34) (== code 92) (== code 127))
            (do (.append sb s start i)
                (case code
                  34 (.append sb "\\\"")
                  92 (.append sb "\\\\")
                  8 (.append sb "\\b")
                  12 (.append sb "\\f")
                  10 (.append sb "\\n")
                  13 (.append sb "\\r")
                  9 (.append sb "\\t")
                  (doto sb (.append "\\u00")
                    (.append (.charAt ^String hex (bit-shift-right code 4)))
                    (.append (.charAt ^String hex (bit-and code 15)))))
                (recur (inc i) (inc i)))
            (recur (inc i) start)))
        (.append sb s start n))))
  (.append sb \"))

(defn write
  "Appends the compact JSON text of the jq value `x` to the StringBuilder `sb`."
  [^StringBuilder sb x]
  (cond
    (nil? x) (.append sb "null")
    (instance? Boolean x) (.append sb (if x "true" "false"))
    (instance? Number x) (.append sb (format-number (double x)))
    (string? x) (write-string sb x)
    (vector? x) (let [n (count x)]
                  (.append sb \[)
                  (dotimes [i n]
                    (when (pos? i) (.append sb \,))
                    (write sb (nth x i)))
                  (.append sb \]))
    (v/obj? x) (let [first? (volatile! true)]
                 (.append sb \{)
                 (doseq [^java.util.Map$Entry e (.entrySet (v/obj-map x))]
                   (if @first? (vreset! first? false) (.append sb \,))
                   (write-string sb (.getKey e))
                   (.append sb \:)
                   (write sb (.getValue e)))
                 (.append sb \}))
    :else (throw (IllegalArgumentException. (str "Not a jq value: " (pr-str x)))))
  sb)

(defn stringify
  "The compact JSON text of the jq value `x`."
  ^String [x]
  (str (write (StringBuilder.) x)))
