(ns fulltext.main
  "Command-line entry point.

      fulltext <input-dir> <output-dir>

  Reads `<input-dir>/docs/*.txt` and `<input-dir>/queries.txt` and writes
  `results.txt` and `stats.txt` into `<output-dir>`."
  (:require [fulltext.core :as ft])
  (:gen-class))

(defn -main [& args]
  (if (= 2 (count args))
    (do (ft/run-directory (first args) (second args))
        (shutdown-agents)
        (System/exit 0))
    (do (binding [*out* *err*]
          (println "usage: fulltext <input-dir> <output-dir>"))
        (System/exit 2))))
