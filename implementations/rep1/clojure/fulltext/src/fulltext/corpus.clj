(ns fulltext.corpus
  "Reading the on-disk input: the `docs/` directory and `queries.txt`."
  (:require [clojure.string :as str]
            [fulltext.analysis :as analysis]
            [fulltext.search :as search])
  (:import (java.io File)
           (java.nio.charset StandardCharsets)
           (java.nio.file Files)))

(set! *warn-on-reflection* true)

(defn read-text
  "Read a file as UTF-8 with no newline translation or trimming."
  ^String [^File f]
  (String. (Files/readAllBytes (.toPath f)) StandardCharsets/UTF_8))

(defn read-docs
  "Read the corpus under `input-dir`: every regular file `docs/<id>.txt`.
  Returns a map from id to text. A missing `docs/` directory is an empty
  corpus."
  [input-dir]
  (let [dir (File. (str input-dir) "docs")]
    (if (.isDirectory dir)
      (into {}
            (keep (fn [^File f]
                    (let [name (.getName f)]
                      (when (and (.isFile f) (.endsWith name ".txt"))
                        [(subs name 0 (- (count name) 4)) (read-text f)]))))
            (.listFiles dir))
      {})))

(defn- strip
  "Strip leading and trailing whitespace (the seven query whitespace chars)."
  ^String [^String s]
  (let [n (.length s)
        start (loop [i 0] (if (and (< i n) (analysis/whitespace? (.charAt s i))) (recur (inc i)) i))
        end (loop [j n] (if (and (> j start) (analysis/whitespace? (.charAt s (dec j)))) (recur (dec j)) j))]
    (.substring s start end)))

(def ^:private k-directive #"%k[ \t]+([0-9]+)[ \t]*")

(defn parse-queries
  "Parse the text of a queries file into a vector of
  `{:number n :text query-text :k k}` maps. Blank lines and `#` comments are
  skipped; `%k <digits>` lines set the limit `k` (initially
  [[fulltext.search/default-k]]) for the queries that follow them."
  [^String text]
  (loop [lines (str/split text #"\n" -1) k search/default-k n 1 out []]
    (if-let [[line & more] (seq lines)]
      (let [line (strip line)]
        (cond
          (or (empty? line) (= \# (first line))) (recur more k n out)
          :else
          (if-let [[_ digits] (re-matches k-directive line)]
            (recur more (parse-long digits) n out)
            (recur more k (inc n) (conj out {:number n :text line :k k})))))
      out)))

(defn read-queries
  "Read and parse `<input-dir>/queries.txt` (see [[parse-queries]])."
  [input-dir]
  (parse-queries (read-text (File. (str input-dir) "queries.txt"))))
