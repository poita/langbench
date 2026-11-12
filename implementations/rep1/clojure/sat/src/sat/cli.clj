(ns sat.cli
  "Command-line entry point: DIMACS CNF on stdin, `SAT`/`UNSAT` on stdout."
  (:require [clojure.java.io :as io]
            [sat.core :as sat])
  (:gen-class))

(defn run
  "Reads DIMACS from `in` (Reader) and returns the output text."
  [in]
  (sat/format-result (sat/solve-dimacs in)))

(defn -main [& _args]
  (try
    (let [text (with-open [rdr (io/reader System/in)] (run rdr))]
      (print text)
      (flush)
      (shutdown-agents))
    (catch Exception e
      (binding [*out* *err*]
        (println "error:" (ex-message e)))
      (System/exit 2))))
