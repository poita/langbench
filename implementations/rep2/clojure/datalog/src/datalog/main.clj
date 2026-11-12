(ns datalog.main
  "Command-line tool: reads a Datalog program on stdin and prints the answers
  to its queries (or `error`) on stdout."
  (:require [datalog.core :as core])
  (:gen-class))

(defn -main
  [& _args]
  (try
    (let [out (core/run-string (slurp *in*))]
      (print out)
      (flush))
    (catch clojure.lang.ExceptionInfo e
      (binding [*out* *err*] (println (ex-message e)))
      (System/exit 1))))
