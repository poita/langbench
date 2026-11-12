(ns datalog.main
  "Command-line tool: reads a Datalog program on stdin and prints the answers
  to its queries on stdout, or `error` if the program is unsafe or not
  stratifiable (exit status 0 in both cases). Unparsable input is reported
  on stderr with exit status 2."
  (:gen-class)
  (:require [datalog.core :as dl]))

(defn -main [& _]
  (let [text (slurp System/in :encoding "UTF-8")
        out (try
              (dl/format-answers (dl/run-program text))
              (catch clojure.lang.ExceptionInfo e
                (cond
                  (dl/error? e) "error\n"
                  :else (do (binding [*out* *err*] (println (ex-message e)))
                            (System/exit 2)))))]
    (print out)
    (flush)))
