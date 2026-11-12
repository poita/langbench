(ns regex.cli
  "Command-line front end. Reads the batch format described in SPEC.md from
  stdin (a pattern, a subject count, then the subjects, repeated) and writes
  one result line per subject to stdout."
  (:require [regex.core :as re])
  (:import (java.io BufferedReader BufferedWriter InputStreamReader
                    OutputStreamWriter Reader Writer)
           (java.nio.charset StandardCharsets))
  (:gen-class))

(set! *warn-on-reflection* true)

(defn format-result
  "Render a match result from `regex.core/match` as an output line (without
  the newline): `no`, or `match <start> <end>|gs,ge|-|...`."
  [result]
  (if-not result
    "no"
    (let [sb (StringBuilder.)]
      (.append sb "match ")
      (.append sb (long (:start result)))
      (.append sb \space)
      (.append sb (long (:end result)))
      (doseq [g (:groups result)]
        (.append sb \|)
        (if g
          (do (.append sb (long (first g)))
              (.append sb \,)
              (.append sb (long (second g))))
          (.append sb \-)))
      (.toString sb))))

(defn- read-line! ^String [^BufferedReader in]
  (or (.readLine in)
      (throw (ex-info "Unexpected end of input" {}))))

(defn process
  "Run the whole batch: read from `in`, write results to `out`."
  [^BufferedReader in ^Writer out]
  (let [n (Long/parseLong (read-line! in))]
    (dotimes [_ n]
      (let [pattern (read-line! in)
            m (Long/parseLong (read-line! in))
            compiled (re/compile pattern)]
        (dotimes [_ m]
          (.write out ^String (format-result (re/match compiled (read-line! in))))
          (.write out "\n"))))
    (.flush out)))

(defn -main [& _]
  (let [in (BufferedReader. (InputStreamReader. System/in StandardCharsets/ISO_8859_1)
                            (* 1 1024 1024))
        out (BufferedWriter. (OutputStreamWriter. System/out StandardCharsets/ISO_8859_1)
                             (* 1 1024 1024))
        status (try
                 ;; deep backtracking recurses; give the matcher a big stack
                 (re/call-with-stack-size (* 1024 1024 1024) #(process in out))
                 0
                 (catch Throwable e
                   (.flush out)
                   (binding [*out* *err*]
                     (println "error:" (.getMessage e)))
                   1))]
    (shutdown-agents)
    (System/exit status)))
