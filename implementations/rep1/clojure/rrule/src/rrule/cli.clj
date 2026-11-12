(ns rrule.cli
  "Command-line tool: reads `<DTSTART> <RRULE> <N>` lines on stdin and writes
  one line of occurrences per input line on stdout."
  (:require [rrule.core :as core])
  (:import (java.io BufferedReader BufferedWriter InputStreamReader
                    OutputStreamWriter))
  (:gen-class))

(set! *warn-on-reflection* true)

(defn run
  "Process every line of `in` (a BufferedReader), writing results to `out`
  (a BufferedWriter).  Returns the number of lines processed."
  [^BufferedReader in ^BufferedWriter out]
  (loop [n 0]
    (if-let [line (.readLine in)]
      (do (.write out (core/expand-line line))
          (.write out "\n")
          (recur (inc n)))
      n)))

(defn -main [& _args]
  (let [in  (BufferedReader. (InputStreamReader. System/in "UTF-8"))
        out (BufferedWriter. (OutputStreamWriter. System/out "UTF-8") 65536)]
    (try
      (run in out)
      (.flush out)
      (shutdown-agents)
      (catch Exception e
        (.flush out)
        (binding [*out* *err*]
          (println "rrule:" (ex-message e)))
        (System/exit 1)))))
