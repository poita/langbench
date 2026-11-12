(ns sat.cli
  "Command-line entry point: reads a DIMACS CNF formula on stdin and prints
  `UNSAT` or `SAT` plus a satisfying assignment on stdout."
  (:require [sat.core :as sat]
            [sat.dimacs :as dimacs])
  (:gen-class))

(defn run
  "Reads all of `in` (a Reader), solves, and writes the answer to `out`."
  [in out]
  (let [{:keys [num-vars clauses]} (dimacs/parse (slurp in))
        result (sat/solve num-vars clauses)]
    (.write ^java.io.Writer out ^String (dimacs/format-result result))
    (.flush ^java.io.Writer out)))

(defn -main [& _]
  (run *in* *out*)
  (shutdown-agents))
