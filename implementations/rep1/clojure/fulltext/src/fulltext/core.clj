(ns fulltext.core
  "Public API of the fulltext library: a small in-memory positional full-text
  search engine with Porter stemming, a boolean/phrase query language and BM25
  ranking.

      (require '[fulltext.core :as ft])

      (def idx (ft/build-index {\"a\" \"The quick brown fox\"
                                \"b\" \"The lazy dog\"}))
      (ft/search idx \"quick OR dog\")
      ;; => [{:rank 1 :id \"a\" :score 0.2877 :snippet \"The quick brown fox\"} ...]

  Higher-level pieces live in their own namespaces: `fulltext.analysis`,
  `fulltext.stemmer`, `fulltext.index`, `fulltext.query`, `fulltext.matching`,
  `fulltext.scoring`, `fulltext.snippet`, `fulltext.search`, `fulltext.corpus`
  and `fulltext.report`."
  (:require [fulltext.analysis :as analysis]
            [fulltext.corpus :as corpus]
            [fulltext.index :as index]
            [fulltext.query :as query]
            [fulltext.report :as report]
            [fulltext.search :as search]
            [fulltext.stemmer :as stemmer])
  (:import (java.io File)
           (java.nio.charset StandardCharsets)
           (java.nio.file Files)))

(defn stem
  "The Porter stem of a lower-case ASCII word."
  [word]
  (stemmer/stem word))

(defn analyze
  "Analyse `text` into a vector of `{:text folded-text :term index-term}`."
  [text]
  (analysis/analyze text))

(defn build-index
  "Build an index from `docs`: a map of document id to text, or a collection
  of `[id text]` pairs."
  [docs]
  (index/build-index docs))

(defn parse-query
  "Parse query text into a tree of `[:atom terms]`, `[:not t]`, `[:and ts]`,
  `[:or ts]`, or `nil` for the empty query (which matches nothing)."
  [text]
  (query/parse text))

(defn search
  "Search `idx` for `query-text`. Options: `:k` — result limit (default 10).
  Returns a vector of `{:rank :id :score :snippet}` maps, best first."
  ([idx query-text] (search/search idx query-text))
  ([idx query-text opts] (search/search idx query-text opts)))

(defn stats
  "Corpus statistics: `{:documents :tokens :terms :avgdl}`."
  [idx]
  (index/stats idx))

(defn- write-file [^File dir ^String name ^String content]
  (Files/write (.toPath (File. dir name))
               (.getBytes content StandardCharsets/UTF_8)
               (make-array java.nio.file.OpenOption 0)))

(defn run-directory
  "Run the whole pipeline: read `<input-dir>/docs/*.txt` and
  `<input-dir>/queries.txt`, and write `results.txt` and `stats.txt` into
  `output-dir` (created if missing)."
  [input-dir output-dir]
  (let [idx (build-index (corpus/read-docs input-dir))
        queries (corpus/read-queries input-dir)
        out (File. (str output-dir))
        results (let [sb (StringBuilder.)]
                  (doseq [{:keys [number text k]} queries]
                    (.append sb ^String (report/format-block
                                         number text (search idx text {:k k}))))
                  (.toString sb))]
    (.mkdirs out)
    (write-file out "results.txt" results)
    (write-file out "stats.txt" (report/format-stats (stats idx)))
    nil))
