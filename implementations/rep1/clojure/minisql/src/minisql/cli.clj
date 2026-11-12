(ns minisql.cli
  "Command-line front end: reads a SQL script from stdin, prints the result
  of every SELECT (and `error` for every failing statement) to stdout."
  (:require [minisql.core :as sql])
  (:gen-class)
  (:import (java.io BufferedWriter OutputStreamWriter)
           (java.nio.charset StandardCharsets)))

(defn -main
  "Entry point: `clojure -M -m minisql.cli < script.sql`."
  [& _args]
  (let [input (String. (.readAllBytes System/in) StandardCharsets/UTF_8)
        out (BufferedWriter. (OutputStreamWriter. System/out StandardCharsets/UTF_8) 65536)]
    (doseq [r (:results (sql/execute-script (sql/empty-db) input))]
      (sql/write-result out r))
    (.flush out))
  (shutdown-agents)
  (System/exit 0))
