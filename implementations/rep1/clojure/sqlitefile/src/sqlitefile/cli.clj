(ns sqlitefile.cli
  "Command-line front end: `sqlitefile <input dir> <output dir>`.

  The input directory holds one `*.sqlite` file and `queries.txt`; for the
  n-th query the result is written to `NNN.txt` in the output directory. A
  query that fails produces a file containing `error`. The exit status is 0
  unless the arguments are unusable."
  (:require [clojure.string :as str]
            [sqlitefile.core :as sf])
  (:import (java.io File))
  (:gen-class))

(set! *warn-on-reflection* true)

(defn- find-database ^File [^File dir]
  (first (filter #(str/ends-with? (.getName ^File %) ".sqlite")
                 (sort-by #(.getName ^File %) (.listFiles dir)))))

(defn read-queries
  "Split the text of a queries file into query lines."
  [^String text]
  (let [lines (str/split text #"\n" -1)]
    (vec (if (= "" (peek lines)) (pop lines) lines))))

(defn run-query
  "Run `line` against `db` (may be nil when the database failed to load) and
  return the text for its result file."
  [db line]
  (try
    (if db (sf/query db line) "error\n")
    (catch Exception _ "error\n")))

(defn process
  "Answer every query of `input-dir` into `output-dir`."
  [^String input-dir ^String output-dir]
  (let [dir (File. input-dir)
        db (try (sf/open (find-database dir)) (catch Exception _ nil))
        text (slurp (File. dir "queries.txt") :encoding "UTF-8")]
    (doseq [[i line] (map-indexed vector (read-queries text))]
      (spit (File. (File. output-dir) (format "%03d.txt" (inc i)))
            (run-query db line)
            :encoding "UTF-8"))))

(defn -main [& args]
  (if (= 2 (count args))
    (do (process (first args) (second args))
        (shutdown-agents))
    (do (binding [*out* *err*]
          (println "usage: sqlitefile <input directory> <output directory>"))
        (System/exit 2))))
