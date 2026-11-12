(ns typeset.test-util
  "Helpers shared by the tests."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [typeset.core :as core]))

(def data-dir
  "The data directory shipped with the test resources."
  "test-resources/data")

(def data (delay (core/load-data data-dir)))

(def small-cfg
  "page-width = 200pt\npage-height = 120pt\nmargin-top = 20pt\nmargin-bottom = 20pt\nmargin-left = 20pt\nmargin-right = 20pt\n")

(defn run
  "Typeset document text `doc` with settings text `cfg` (nil for none)."
  ([doc] (run doc nil))
  ([doc cfg] (core/typeset-strings doc cfg @data)))

(defn layout [doc cfg] (get (run doc cfg) "layout.txt"))
(defn report [doc cfg] (get (run doc cfg) "report.txt"))
(defn error [doc cfg] (some-> (get (run doc cfg) "error.txt") str/trim))

(defn report-map
  "The report of a run as a map of key -> long."
  [doc cfg]
  (into {} (for [l (rest (str/split-lines (report doc cfg)))
                 :let [[k v] (str/split l #" ")]]
             [k (parse-long v)])))

(defn lines-of
  "The lines of a layout text."
  [s]
  (str/split-lines s))
