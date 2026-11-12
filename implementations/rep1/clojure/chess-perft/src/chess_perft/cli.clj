(ns chess-perft.cli
  "Command-line front end: reads perft/divide queries from stdin, one per
  line, and writes one result per query to stdout.

  Query lines are `<fen: 6 fields> <depth>` or
  `<fen: 6 fields> divide <depth>`."
  (:require [chess-perft.core :as chess]
            [clojure.string :as str])
  (:import [java.io BufferedReader BufferedWriter InputStreamReader OutputStreamWriter Reader Writer])
  (:gen-class))

(set! *warn-on-reflection* true)

(defn parse-query
  "Parses a query line into `{:fen s :depth n :divide? bool}`."
  [^String line]
  (let [fields (str/split line #" ")
        n      (count fields)
        divide? (= "divide" (nth fields 6))]
    (when-not (<= 7 n 8)
      (throw (ex-info "Malformed query" {:line line})))
    {:fen     (str/join " " (take 6 fields))
     :divide? (and (== n 8) divide?)
     :depth   (Long/parseLong (peek fields))}))

(defn- query->lines
  [{:keys [fen depth divide?]}]
  (let [pos (chess/parse-fen fen)]
    (if divide?
      (let [rows (chess/divide pos depth)]
        (concat (map (fn [[mv cnt]] (str mv " " cnt)) rows)
                [(str "total " (reduce + 0 (map second rows)))]))
      [(str (chess/perft pos depth))])))

(defn answer
  "The output lines (a seq of strings) for the query line `line`."
  [line]
  (query->lines (parse-query line)))

(defn run
  "Reads queries from `rdr` and writes the answers to `wtr`; blank lines are
  skipped. Does not close either."
  [^BufferedReader rdr ^Writer wtr]
  (loop []
    (when-let [^String line (.readLine rdr)]
      (when-not (str/blank? line)
        (doseq [^String l (answer line)]
          (.write wtr l)
          (.write wtr "\n"))
        (.flush wtr))
      (recur))))

(defn -main
  "Entry point: stdin -> stdout."
  [& _]
  (let [rdr (BufferedReader. (InputStreamReader. System/in "UTF-8"))
        wtr (BufferedWriter. (OutputStreamWriter. System/out "UTF-8"))]
    (run rdr wtr)
    (.flush wtr)))
