(ns jsonschema.json
  "A small, strict JSON (RFC 8259) parser producing the data model used by the
  validator.

  Data model:

  | JSON    | Clojure                                         |
  |---------|-------------------------------------------------|
  | null    | `nil`                                           |
  | boolean | `true` / `false`                                |
  | number  | `java.math.BigDecimal` (exact, never a double)  |
  | string  | `String`                                        |
  | array   | persistent vector                               |
  | object  | persistent map with `String` keys               |

  Numbers keep the exact value of their literal: `1`, `1.0` and `1e0` all
  parse to numerically equal decimals."
  (:import (java.math BigDecimal)))

(set! *warn-on-reflection* true)

(defn- fail [^String s i msg]
  (throw (ex-info (str "JSON parse error at offset " i ": " msg)
                  {:type ::parse-error :offset i :input-length (.length s)})))

(defn- char-at
  "The char at index `i` as an int, or -1 past the end."
  ^long [^String s ^long i]
  (if (< i (.length s)) (int (.charAt s i)) -1))

(defn- skip-ws ^long [^String s ^long i]
  (loop [i i]
    (let [c (char-at s i)]
      (if (or (== c 32) (== c 10) (== c 13) (== c 9))
        (recur (inc i))
        i))))

(defn- digit? [^long c] (and (>= c 48) (<= c 57)))

(defn- skip-digits ^long [^String s ^long i]
  (loop [i i] (if (digit? (char-at s i)) (recur (inc i)) i)))

(defn- hex4 ^long [^String s ^long i]
  (loop [k 0, v 0]
    (if (== k 4)
      v
      (let [d (Character/digit (int (char-at s (+ i k))) 16)]
        (when (neg? d) (fail s (+ i k) "bad \\u escape"))
        (recur (inc k) (+ (* v 16) d))))))

(defn- parse-escape!
  "Handles the escape whose backslash is at `j`, appending to `sb`; returns
  the index after the escape."
  ^long [^String s ^StringBuilder sb ^long j]
  (let [e (char-at s (inc j))]
    (case (int e)
      34 (do (.append sb \") (+ j 2))
      92 (do (.append sb \\) (+ j 2))
      47 (do (.append sb \/) (+ j 2))
      98 (do (.append sb \backspace) (+ j 2))
      102 (do (.append sb \formfeed) (+ j 2))
      110 (do (.append sb \newline) (+ j 2))
      114 (do (.append sb \return) (+ j 2))
      116 (do (.append sb \tab) (+ j 2))
      117 (do (.append sb (char (hex4 s (+ j 2)))) (+ j 6))
      (fail s j "bad escape"))))

(defn- parse-string
  "Parses the string whose opening quote is at `i`. Returns [string next-index]."
  [^String s ^long i]
  (let [start (inc i)]
    (loop [j start]
      (let [c (char-at s j)]
        (cond
          (== c -1) (fail s i "unterminated string")
          (== c 34) [(.substring s start j) (inc j)]
          (< c 32) (fail s j "control character in string")
          (== c 92) (let [sb (StringBuilder.)]
                      (.append sb s start (int j))
                      (loop [j j]
                        (let [c (char-at s j)]
                          (cond
                            (== c -1) (fail s i "unterminated string")
                            (== c 34) [(.toString sb) (inc j)]
                            (< c 32) (fail s j "control character in string")
                            (== c 92) (recur (parse-escape! s sb j))
                            :else (do (.append sb (char c)) (recur (inc j)))))))
          :else (recur (inc j)))))))

(defn- parse-number [^String s ^long i]
  (let [j (if (== (char-at s i) 45) (inc i) i)
        c (char-at s j)
        j (cond
            (== c 48) (inc j)
            (and (>= c 49) (<= c 57)) (skip-digits s j)
            :else (fail s j "bad number"))
        j (if (== (char-at s j) 46)
            (let [k (inc j)]
              (when-not (digit? (char-at s k)) (fail s k "bad fraction"))
              (skip-digits s k))
            j)
        j (if (let [c (char-at s j)] (or (== c 101) (== c 69)))
            (let [k (inc j)
                  k (if (let [c (char-at s k)] (or (== c 43) (== c 45))) (inc k) k)]
              (when-not (digit? (char-at s k)) (fail s k "bad exponent"))
              (skip-digits s k))
            j)]
    [(BigDecimal. (.substring s (int i) (int j))) j]))

(declare parse-value)

(defn- parse-array [^String s ^long i]
  (let [i (skip-ws s (inc i))]
    (if (== (char-at s i) 93)
      [[] (inc i)]
      (loop [i i, acc (transient [])]
        (let [[v j] (parse-value s i)
              j (skip-ws s j)
              acc (conj! acc v)
              c (char-at s j)]
          (cond
            (== c 44) (recur (skip-ws s (inc j)) acc)
            (== c 93) [(persistent! acc) (inc j)]
            :else (fail s j "expected , or ]")))))))

(defn- parse-object [^String s ^long i]
  (let [i (skip-ws s (inc i))]
    (if (== (char-at s i) 125)
      [{} (inc i)]
      (loop [i i, acc (transient {})]
        (when-not (== (char-at s i) 34) (fail s i "expected object key"))
        (let [[k j] (parse-string s i)
              j (skip-ws s j)]
          (when-not (== (char-at s j) 58) (fail s j "expected :"))
          (let [[v j] (parse-value s (skip-ws s (inc j)))
                j (skip-ws s j)
                acc (assoc! acc k v)
                c (char-at s j)]
            (cond
              (== c 44) (recur (skip-ws s (inc j)) acc)
              (== c 125) [(persistent! acc) (inc j)]
              :else (fail s j "expected , or }"))))))))

(defn- literal [^String s ^long i ^String word value]
  (if (.startsWith s word (int i))
    [value (+ i (.length word))]
    (fail s i "bad literal")))

(defn- parse-value [^String s ^long i]
  (let [c (char-at s i)]
    (case (int c)
      -1 (fail s i "unexpected end of input")
      123 (parse-object s i)
      91 (parse-array s i)
      34 (parse-string s i)
      116 (literal s i "true" true)
      102 (literal s i "false" false)
      110 (literal s i "null" nil)
      (parse-number s i))))

(defn parse
  "Parses `s`, a string holding exactly one JSON value, and returns the value
  in the data model described in the namespace docstring. Throws `ex-info`
  (with `:type ::parse-error`) on malformed input."
  [^String s]
  (let [[v j] (parse-value s (skip-ws s 0))
        j (skip-ws s j)]
    (when (< j (.length s)) (fail s j "trailing characters"))
    v))
