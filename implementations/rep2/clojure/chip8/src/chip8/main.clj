(ns chip8.main
  "Command-line entry point: reads a job on stdin, prints the report."
  (:require [chip8.core :as core])
  (:gen-class))

(defn -main [& _]
  (let [out (core/emulate (slurp *in*))]
    (print out)
    (flush)))
