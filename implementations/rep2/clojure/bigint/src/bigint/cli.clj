(ns bigint.cli
  "Command-line entry point: one query per line on stdin, one result per line
  on stdout. Run with `clojure -M:run < input.txt` (or `./run.sh`)."
  (:require [bigint.query :as query])
  (:import (java.io BufferedReader BufferedWriter InputStreamReader
                    OutputStreamWriter Reader Writer)
           (java.nio.charset StandardCharsets)))

(set! *warn-on-reflection* true)

(defn run
  "Read queries from `in` (a Reader) and write one result line, terminated by
  \\n, per query to `out` (a Writer). Does not close either."
  [^Reader in ^Writer out]
  (let [rdr (if (instance? BufferedReader in) in (BufferedReader. in 65536))]
    (loop []
      (when-let [line (.readLine ^BufferedReader rdr)]
        (.write out (query/evaluate line))
        (.write out "\n")
        (recur)))
    (.flush out)))

(defn -main
  [& _args]
  (let [in  (InputStreamReader. System/in StandardCharsets/UTF_8)
        out (BufferedWriter. (OutputStreamWriter. System/out StandardCharsets/UTF_8)
                             65536)]
    (run in out)))
