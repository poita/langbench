(ns spreadsheet.main
  "Command-line entry point: reads commands from stdin (UTF-8), writes the
  results of `get` and `dump` to stdout."
  (:require [spreadsheet.cli :as cli])
  (:import (java.io BufferedWriter OutputStreamWriter)
           (java.nio.charset StandardCharsets))
  (:gen-class))

(defn run-stdin []
  (let [text (String. (.readAllBytes System/in) StandardCharsets/UTF_8)
        out (BufferedWriter. (OutputStreamWriter. System/out StandardCharsets/UTF_8) 65536)]
    (cli/run (cli/split-lines text)
             (fn [^String line] (.write out line) (.write out "\n")))
    (.flush out)))

(defn -main [& _]
  ;; Run on a thread with a large stack: evaluation recurses over syntax trees.
  (let [failure (volatile! nil)
        t (Thread. nil
                   (fn [] (try (run-stdin) (catch Throwable e (vreset! failure e))))
                   "spreadsheet" (* 512 1024 1024))]
    (.start t)
    (.join t)
    (shutdown-agents)
    (when-let [e @failure]
      (.printStackTrace ^Throwable e)
      (System/exit 1))))
