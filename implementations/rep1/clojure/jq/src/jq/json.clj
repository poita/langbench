(ns jq.json
  "A self-contained JSON reader and writer (RFC 8259) producing and consuming
  jq values (see [[jq.value]]). Objects keep document order."
  (:require [jq.value :as v])
  (:import [java.math BigDecimal]))

;; ---------------------------------------------------------------- parsing

(defn- fail [^String s i msg]
  (throw (ex-info (str "JSON parse error at offset " i ": " msg)
                  {:type :jq/json-error :offset i})))

(defn- skip-ws ^long [^String s ^long i]
  (let [n (.length s)]
    (loop [i i]
      (if (< i n)
        (let [c (.charAt s i)]
          (if (or (v/ceq c \space) (v/ceq c \newline) (v/ceq c \tab) (v/ceq c \return))
            (recur (inc i))
            i))
        i))))

(defn- hex4 ^long [^String s ^long i]
  (when (> (+ i 4) (.length s)) (fail s i "truncated \\u escape"))
  (try (Long/parseLong (.substring s i (+ i 4)) 16)
       (catch NumberFormatException _ (fail s i "bad \\u escape"))))

(defn- parse-escaped-string
  "Slow path of [[parse-string-body]]: the string has escapes. `first-bs` is
  the index of the first backslash."
  [^String s ^longs p ^long start ^long first-bs]
  (let [n (.length s)
        sb (StringBuilder.)]
    (.append sb s (int start) (int first-bs))
    (loop [i first-bs]
      (when (>= i n) (fail s i "unterminated string"))
      (let [c (.charAt s i)]
        (cond
          (v/ceq c \") (do (aset p 0 (inc i)) (.toString sb))
          (v/ceq c \\)
          (let [e (if (< (inc i) n) (.charAt s (inc i)) (fail s i "bad escape"))]
            (case e
              \" (do (.append sb \") (recur (+ i 2)))
              \\ (do (.append sb \\) (recur (+ i 2)))
              \/ (do (.append sb \/) (recur (+ i 2)))
              \b (do (.append sb \backspace) (recur (+ i 2)))
              \f (do (.append sb \formfeed) (recur (+ i 2)))
              \n (do (.append sb \newline) (recur (+ i 2)))
              \r (do (.append sb \return) (recur (+ i 2)))
              \t (do (.append sb \tab) (recur (+ i 2)))
              \u (do (.append sb (char (hex4 s (+ i 2)))) (recur (+ i 6)))
              (fail s i "bad escape")))
          :else (do (.append sb c) (recur (inc i))))))))

(defn- parse-string-body
  "Parses a string whose opening quote is just before `start`; returns the
  string and stores the index after the closing quote in `p`."
  [^String s ^longs p ^long start]
  (let [n (.length s)]
    (loop [i start]
      (when (>= i n) (fail s i "unterminated string"))
      (let [c (.charAt s i)]
        (cond
          (v/ceq c \") (do (aset p 0 (inc i)) (.substring s start i))
          (v/ceq c \\) (parse-escaped-string s p start i)
          :else (recur (inc i)))))))

(defn- number-char? [c]
  (or (and (>= (int c) 48) (<= (int c) 57)) (v/ceq c \-) (v/ceq c \+) (v/ceq c \.) (v/ceq c \e) (v/ceq c \E)))

(declare parse-value)

(defn- parse-array [^String s ^longs p ^long depth]
  (let [i (skip-ws s (aget p 0))]
    (if (and (< i (.length s)) (v/ceq (.charAt s i) \]))
      (do (aset p 0 (inc i)) [])
      (loop [acc (transient [])]
        (let [x (parse-value s p depth)
              acc (conj! acc x)
              i (skip-ws s (aget p 0))]
          (when (>= i (.length s)) (fail s i "unterminated array"))
          (let [c (.charAt s i)]
            (cond (v/ceq c \,) (do (aset p 0 (inc i)) (recur acc))
                  (v/ceq c \]) (do (aset p 0 (inc i)) (persistent! acc))
                  :else (fail s i "expected , or ]"))))))))

(defn- parse-object [^String s ^longs p ^long depth]
  (let [i (skip-ws s (aget p 0))]
    (if (and (< i (.length s)) (v/ceq (.charAt s i) \}))
      (do (aset p 0 (inc i)) v/empty-obj)
      (loop [m (transient {}) ks (transient [])]
        (let [i (skip-ws s (aget p 0))]
          (when-not (and (< i (.length s)) (v/ceq (.charAt s i) \"))
            (fail s i "expected object key"))
          (let [k (parse-string-body s p (inc i))
                i (skip-ws s (aget p 0))]
            (when-not (and (< i (.length s)) (v/ceq (.charAt s i) \:))
              (fail s i "expected :"))
            (aset p 0 (inc i))
            (let [x (parse-value s p depth)
                  fresh? (identical? ::none (get m k ::none))
                  m (assoc! m k x)
                  ks (if fresh? (conj! ks k) ks)
                  i (skip-ws s (aget p 0))]
              (when (>= i (.length s)) (fail s i "unterminated object"))
              (let [c (.charAt s i)]
                (cond (v/ceq c \,) (do (aset p 0 (inc i)) (recur m ks))
                      (v/ceq c \}) (do (aset p 0 (inc i))
                                    (v/obj-make (persistent! m) (persistent! ks)))
                      :else (fail s i "expected , or }"))))))))))

(defn- parse-literal [^String s ^longs p ^String word value]
  (let [i (aget p 0)]
    (if (.startsWith s word (int i))
      (do (aset p 0 (+ i (.length word))) value)
      (fail s i "invalid literal"))))

(defn- parse-value [^String s ^longs p ^long depth]
  (when (> depth 10000) (fail s (aget p 0) "nesting too deep"))
  (let [i (skip-ws s (aget p 0))]
    (when (>= i (.length s)) (fail s i "unexpected end of input"))
    (aset p 0 i)
    (let [c (.charAt s i)]
      (case c
        \{ (do (aset p 0 (inc i)) (parse-object s p (inc depth)))
        \[ (do (aset p 0 (inc i)) (parse-array s p (inc depth)))
        \" (parse-string-body s p (inc i))
        \t (parse-literal s p "true" true)
        \f (parse-literal s p "false" false)
        \n (parse-literal s p "null" nil)
        (if (or (v/ceq c \-) (and (>= (int c) 48) (<= (int c) 57)))
          (let [n (.length s)
                end (loop [j (inc i)] (if (and (< j n) (number-char? (.charAt s j))) (recur (inc j)) j))]
            (aset p 0 end)
            (try (Double/valueOf (Double/parseDouble (.substring s i end)))
                 (catch NumberFormatException _ (fail s i "invalid number"))))
          (fail s i "unexpected character"))))))

(defn parse
  "Parses the JSON text `s` (exactly one value, optionally surrounded by
  whitespace) into a jq value. Throws `ex-info` with `{:type :jq/json-error}`
  on malformed input."
  [^String s]
  (let [p (long-array 1)
        x (parse-value s p 0)
        i (skip-ws s (aget p 0))]
    (when (< i (.length s)) (fail s i "trailing characters after value"))
    x))

;; ------------------------------------------------------------ serializing

(defn- needs-escape? [^String s]
  (let [n (.length s)]
    (loop [i 0]
      (if (< i n)
        (let [c (.charAt s i)]
          (if (or (< (int c) 0x20) (v/ceq c \") (v/ceq c \\) (== (int c) 0x7f))
            true
            (recur (inc i))))
        false))))

(defn write-string!
  "Appends `s` to the StringBuilder `sb` as a JSON string literal."
  [^StringBuilder sb ^String s]
  (.append sb \")
  (if-not (needs-escape? s)
    (.append sb s)
    (dotimes [i (.length s)]
      (let [c (.charAt s i)]
        (cond
          (v/ceq c \") (.append sb "\\\"")
          (v/ceq c \\) (.append sb "\\\\")
          (v/ceq c \newline) (.append sb "\\n")
          (v/ceq c \return) (.append sb "\\r")
          (v/ceq c \tab) (.append sb "\\t")
          (v/ceq c \backspace) (.append sb "\\b")
          (v/ceq c \formfeed) (.append sb "\\f")
          (or (< (int c) 0x20) (== (int c) 0x7f))
          (do (.append sb "\\u00")
              (.append sb (Character/forDigit (bit-shift-right (int c) 4) 16))
              (.append sb (Character/forDigit (bit-and (int c) 15) 16)))
          :else (.append sb c)))))
  (.append sb \"))

(defn write-number!
  "Appends the double `d` to `sb`: integers without a decimal point, other
  values in the shortest decimal form that round-trips."
  [^StringBuilder sb ^double d]
  (cond
    (Double/isNaN d) (.append sb "null")
    (Double/isInfinite d) (.append sb (if (pos? d) "1.7976931348623157e308" "-1.7976931348623157e308"))
    (and (== d (Math/rint d)) (< (Math/abs d) 1e17))
    (if (and (zero? d) (neg? (Double/doubleToRawLongBits d)))
      (.append sb "-0")
      (.append sb (long d)))
    :else (.append sb (.toPlainString (.stripTrailingZeros (BigDecimal. (Double/toString d)))))))

(defn write-value!
  "Appends the compact JSON text of the jq value `x` to `sb`."
  [^StringBuilder sb x]
  (cond
    (nil? x) (.append sb "null")
    (true? x) (.append sb "true")
    (false? x) (.append sb "false")
    (instance? Double x) (write-number! sb (double x))
    (string? x) (write-string! sb x)
    (vector? x) (do (.append sb \[)
                    (let [n (count x)]
                      (dotimes [i n]
                        (when (pos? i) (.append sb \,))
                        (write-value! sb (nth x i))))
                    (.append sb \]))
    (v/object? x) (do (.append sb \{)
                      (let [ks (v/obj-keys x) n (count ks)]
                        (dotimes [i n]
                          (let [k (nth ks i)]
                            (when (pos? i) (.append sb \,))
                            (write-string! sb k)
                            (.append sb \:)
                            (write-value! sb (v/obj-get x k)))))
                      (.append sb \}))
    :else (throw (IllegalArgumentException. (str "not a jq value: " (pr-str x)))))
  sb)

(defn stringify
  "The compact JSON text of the jq value `x`."
  [x]
  (str (write-value! (StringBuilder.) x)))
