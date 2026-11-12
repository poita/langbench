(ns typeset.cli
  "Command-line entry point: `typeset <input directory> <output directory>`.

  Reads `document.cdx` (and optionally `settings.cfg`) from the input
  directory, resolves `data/` relative to the current directory and writes
  either `layout.txt` and `report.txt`, or `error.txt`, into the output
  directory. The exit status is 0 even for an invalid document."
  (:require [typeset.core :as core])
  (:gen-class))

(defn -main [& args]
  (if (= 2 (count args))
    (let [[in out] args]
      (core/write-outputs! out (core/typeset in))
      (shutdown-agents)
      (System/exit 0))
    (do (binding [*out* *err*]
          (println "usage: typeset <input directory> <output directory>"))
        (System/exit 2))))
