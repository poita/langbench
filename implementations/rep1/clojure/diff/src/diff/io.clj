(ns diff.io
  "Parsing and printing of the line-oriented request/response format used by
  the command-line tool (see the README)."
  (:require [diff.script :as script])
  (:import (java.io InputStream OutputStream)
           (java.nio.charset StandardCharsets)))

(set! *warn-on-reflection* true)

(defn- split-lines
  "Splits `s` at `\\n` characters only. A missing final newline is tolerated;
  no `\\r` handling is done (content is taken verbatim)."
  [^String s]
  (let [len (.length s)]
    (loop [start 0, out (transient [])]
      (if (>= start len)
        (persistent! out)
        (let [nl (.indexOf s (int \newline) (int start))
              end (if (neg? nl) len nl)]
          (recur (inc end) (conj! out (.substring s start end))))))))

(defn- parse-count [^String s]
  (let [t (.trim s)]
    (try (Long/parseLong t)
         (catch NumberFormatException _
           (throw (ex-info "Invalid count line" {:line s}))))))

(defn- take-block
  "Reads a count line then that many lines from the vector `lines` starting at
  `pos`. Returns `[block next-pos]`."
  [lines pos]
  (when (>= pos (count lines))
    (throw (ex-info "Unexpected end of input" {:pos pos})))
  (let [k (parse-count (lines pos))
        start (inc pos)
        end (+ start k)]
    (when (or (neg? k) (> end (count lines)))
      (throw (ex-info "Truncated input" {:count k})))
    [(subvec lines start end) end]))

(defn parse-request
  "Parses the whole input text. Returns `{:mode :diff, :a [...], :b [...]}`
  or `{:mode :patch, :a [...], :script [...]}` where `:script` is parsed."
  [^String text]
  (let [lines (split-lines text)
        mode (when (seq lines) (.trim ^String (lines 0)))]
    (case mode
      "diff" (let [[a p] (take-block lines 1)
                   [b _] (take-block lines p)]
               {:mode :diff :a a :b b})
      "patch" (let [[a p] (take-block lines 1)
                    [s _] (take-block lines p)]
                {:mode :patch :a a :script (script/parse s)})
      (throw (ex-info "Unknown mode" {:mode mode})))))

(defn render-response
  "Renders the output lines preceded by their count, each newline-terminated,
  as a string."
  [lines]
  (let [sb (StringBuilder.)]
    (.append sb (count lines)) (.append sb \newline)
    (doseq [^String l lines] (.append sb l) (.append sb \newline))
    (.toString sb)))

(defn read-all-text
  "Reads `in` fully and decodes it as UTF-8."
  ^String [^InputStream in]
  (String. (.readAllBytes in) StandardCharsets/UTF_8))

(defn write-text
  "Writes `s` to `out` as UTF-8 and flushes."
  [^OutputStream out ^String s]
  (.write out (.getBytes s StandardCharsets/UTF_8))
  (.flush out))
