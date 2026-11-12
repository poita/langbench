(ns depresolve.cli
  "Command-line entry point: reads a registry and root manifest from stdin and
  prints the resolution (or `unsatisfiable`) on stdout."
  (:require [depresolve.core :as core])
  (:gen-class))

(set! *warn-on-reflection* true)

(defn -main
  [& _args]
  (let [text (slurp *in* :encoding "UTF-8")
        out (core/resolve-text text)]
    (print out)
    (flush)))
