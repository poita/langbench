(ns fulltext.report
  "Formatting results and statistics as the text files the CLI writes."
  (:require [clojure.string :as str])
  (:import (java.util Locale)))

(set! *warn-on-reflection* true)

(defn format-score
  "A score with exactly four digits after the decimal point."
  [score]
  (String/format Locale/ROOT "%.4f" (object-array [(double score)])))

(defn format-block
  "The results.txt block for one query: `number`, its `text` and its `hits`
  (as returned by [[fulltext.search/search]])."
  [number text hits]
  (str "QUERY " number " " text "\n"
       "HITS " (count hits) "\n"
       (apply str
              (map (fn [{:keys [rank id score snippet]}]
                     (str rank "\t" id "\t" (format-score score) "\t" snippet "\n"))
                   hits))))

(defn format-stats
  "The contents of stats.txt for a stats map from [[fulltext.index/stats]]."
  [{:keys [documents tokens terms avgdl]}]
  (str "documents " documents "\n"
       "tokens " tokens "\n"
       "terms " terms "\n"
       "avgdl " (format-score avgdl) "\n"))
