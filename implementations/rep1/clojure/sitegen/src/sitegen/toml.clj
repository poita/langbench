(ns sitegen.toml
  "A reader for the small TOML subset used by `site.toml` and by content-file
  front matter: one `key = value` assignment per line, `#` comments, and
  values that are basic strings, integers, booleans or one-line arrays of
  strings.  There are no tables, dotted keys or multi-line values.

      (require '[sitegen.toml :as toml])
      (toml/parse-document \"title = \\\"Hi\\\"\\nn = 3\")
      ;; => {\"title\" \"Hi\", \"n\" 3}   (a java.util.LinkedHashMap)"
  (:import (java.util LinkedHashMap)))

(set! *warn-on-reflection* true)

(defn- fail
  "Throws a parse error for line number `line-no`."
  [line-no msg]
  (throw (ex-info (str "TOML error on line " line-no ": " msg)
                  {:type ::parse-error :line line-no})))

(defn- blank-char? [c] (or (= c \space) (= c \tab)))

(defn- skip-blanks
  "Index of the first character at or after `i` that is not a space or tab."
  ^long [^String s ^long i]
  (loop [i i]
    (if (and (< i (.length s)) (blank-char? (.charAt s i))) (recur (inc i)) i)))

(defn- key-char? [c]
  (or (<= (int \a) (int c) (int \z)) (<= (int \A) (int c) (int \Z))
      (<= (int \0) (int c) (int \9)) (= c \_) (= c \-)))

(defn- hex-value [c]
  (let [d (Character/digit (char c) 16)]
    (when (neg? d) (throw (ex-info "bad hex digit" {})))
    d))

(defn- parse-string
  "Parses the basic string whose opening quote is at index `i`.  Returns
  [string index-after-closing-quote]."
  [^String s ^long i line-no]
  (let [n (.length s)
        sb (StringBuilder.)]
    (loop [j (inc i)]
      (when (>= j n) (fail line-no "unterminated string"))
      (let [c (.charAt s j)]
        (cond
          (= c \") [(.toString sb) (inc j)]

          (= c \\)
          (do (when (>= (inc j) n) (fail line-no "unterminated escape"))
              (let [e (.charAt s (inc j))]
                (case e
                  \" (do (.append sb \") (recur (+ j 2)))
                  \\ (do (.append sb \\) (recur (+ j 2)))
                  \n (do (.append sb \newline) (recur (+ j 2)))
                  \t (do (.append sb \tab) (recur (+ j 2)))
                  \r (do (.append sb \return) (recur (+ j 2)))
                  \u (do (when (> (+ j 6) n) (fail line-no "short \\u escape"))
                         (let [cp (try (reduce (fn [acc k] (+ (* 16 (long acc)) (long (hex-value (.charAt s (+ j 2 k))))))
                                               0 (range 4))
                                       (catch clojure.lang.ExceptionInfo _ (fail line-no "bad \\u escape")))]
                           (.appendCodePoint sb (int cp))
                           (recur (+ j 6))))
                  (fail line-no (str "unknown escape \\" e)))))

          :else (do (.append sb c) (recur (inc j))))))))

(defn- parse-array
  "Parses an array of strings whose `[` is at index `i`."
  [^String s ^long i line-no]
  (loop [j (skip-blanks s (inc i)) acc []]
    (when (>= j (.length s)) (fail line-no "unterminated array"))
    (let [c (.charAt s j)]
      (cond
        (= c \]) [acc (inc j)]
        (= c \") (let [[v k] (parse-string s j line-no)
                       k (skip-blanks s k)]
                   (when (>= k (.length s)) (fail line-no "unterminated array"))
                   (case (.charAt s k)
                     \, (recur (skip-blanks s (inc k)) (conj acc v))
                     \] [(conj acc v) (inc k)]
                     (fail line-no "expected , or ]")))
        :else (fail line-no "expected a string in array")))))

(defn- parse-integer [^String s ^long i line-no]
  (let [n (.length s)
        neg? (and (< i n) (= (.charAt s i) \-))
        d0 (if neg? (inc i) i)
        e (loop [j d0] (if (and (< j n) (Character/isDigit (.charAt s j)) (< (int (.charAt s j)) 128)) (recur (inc j)) j))]
    (when (= e d0) (fail line-no "bad value"))
    (when (and (> (- e d0) 1) (= (.charAt s d0) \0)) (fail line-no "leading zero"))
    [(Long/parseLong (.substring s (int i) (int e))) e]))

(defn- parse-value
  "Parses the value starting at index `i`.  Returns [value next-index]."
  [^String s ^long i line-no]
  (when (>= i (.length s)) (fail line-no "missing value"))
  (let [c (.charAt s i)]
    (cond
      (= c \") (parse-string s i line-no)
      (= c \[) (parse-array s i line-no)
      (.startsWith s "true" (int i)) [true (+ i 4)]
      (.startsWith s "false" (int i)) [false (+ i 5)]
      (or (= c \-) (<= (int \0) (int c) (int \9))) (parse-integer s i line-no)
      :else (fail line-no "bad value"))))

(defn- parse-line!
  "Parses one line, putting an assignment into `m`."
  [^LinkedHashMap m ^String line line-no]
  (let [i (skip-blanks line 0)
        n (.length line)]
    (when (and (< i n) (not= (.charAt line i) \#))
      (let [k-end (loop [j i] (if (and (< j n) (key-char? (.charAt line j))) (recur (inc j)) j))
            _ (when (= k-end i) (fail line-no "expected a key"))
            eq (skip-blanks line k-end)
            _ (when-not (and (< eq n) (= (.charAt line eq) \=)) (fail line-no "expected ="))
            v0 (skip-blanks line (inc eq))
            [v v-end] (parse-value line v0 line-no)
            rest-start (skip-blanks line v-end)]
        (when (and (< rest-start n) (not= (.charAt line rest-start) \#))
          (fail line-no "unexpected text after value"))
        (.put m (.substring line (int i) (int k-end)) v)))))

(defn parse-document
  "Parses the TOML-subset document `text` and returns its assignments as an
  insertion-ordered `java.util.LinkedHashMap` from string keys to values:
  strings, longs, booleans and vectors of strings.  Throws `ex-info` with
  `:type :sitegen.toml/parse-error` on malformed input."
  ^LinkedHashMap [^String text]
  (let [m (LinkedHashMap.)
        n (.length text)]
    (loop [start 0 line-no 1]
      (when (<= start n)
        (let [nl (.indexOf text (int \newline) (int start))
              end (if (neg? nl) n nl)]
          (parse-line! m (.substring text (int start) (int end)) line-no)
          (when-not (neg? nl) (recur (inc end) (inc line-no))))))
    m))
