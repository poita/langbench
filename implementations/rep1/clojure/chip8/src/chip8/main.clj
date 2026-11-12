(ns chip8.main
  "Command-line entry point: reads the input on stdin, writes the report to
  stdout."
  (:require [chip8.core :as core])
  (:gen-class))

(defn -main
  [& _args]
  (try
    (let [out (core/run-text (slurp *in*))]
      (print out)
      (flush)
      (shutdown-agents))
    (catch Exception e
      (binding [*out* *err*]
        (println "chip8:" (ex-message e)))
      (System/exit 1))))
