(ns typeinfer.main
  "Command-line entry point: reads a program on stdin, writes one line per
  declaration on stdout (see the README for the format)."
  (:require [typeinfer.core :as core])
  (:import (java.io BufferedWriter OutputStreamWriter))
  (:gen-class))

(set! *warn-on-reflection* true)

(defn run
  "Read the program from `in` (an InputStream), write the report to `out` (an
  OutputStream). Returns the exit code: 0, or 1 if the input is malformed
  (declarations before the malformed one are still reported)."
  [in out]
  (let [src (slurp in :encoding "UTF-8")
        w (BufferedWriter. (OutputStreamWriter. ^java.io.OutputStream out "UTF-8") 65536)]
    (try
      (doseq [r (core/infer-program src)]
        (.write w ^String (core/format-result r))
        (.write w "\n"))
      0
      (catch clojure.lang.ExceptionInfo e
        (if (= :syntax (:kind (ex-data e)))
          (do (binding [*out* *err*] (println (ex-message e))) 1)
          (throw e)))
      (finally (.flush w)))))

(defn -main [& _]
  (let [code (core/with-deep-stack #(run System/in System/out))]
    (shutdown-agents)
    (System/exit (long code))))
