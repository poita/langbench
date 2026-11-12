(ns textbuffer.cli
  "Command-line tool: reads a document and commands from stdin and writes the
  output of every `print` command to stdout (see SPEC.md).

  Input format: a line with the number N of document lines, N document lines
  taken verbatim, then one command per line."
  (:require [textbuffer.buffer :as buf]
            [textbuffer.command :as command])
  (:import (java.io BufferedReader BufferedWriter InputStreamReader
                    OutputStreamWriter Reader Writer)
           (java.nio.charset StandardCharsets))
  (:gen-class))

(set! *warn-on-reflection* true)

(defn- read-document-lines
  "Reads the line count and then that many lines from `rdr`."
  [^BufferedReader rdr]
  (let [header (.readLine rdr)
        n (if header (Long/parseLong (.trim header)) 0)]
    (loop [i 0 acc (transient [])]
      (if (< i n)
        (recur (inc i) (conj! acc (or (.readLine rdr) "")))
        (persistent! acc)))))

(defn run
  "Runs the whole program: reads from `in`, writes `print` output to `out`.
  Neither is closed or flushed."
  [^Reader in ^Writer out]
  (let [rdr (if (instance? BufferedReader in) in (BufferedReader. in (* 1 1024 1024)))
        initial (read-document-lines rdr)]
    (loop [b (buf/from-lines initial)]
      (when-let [line (.readLine ^BufferedReader rdr)]
        (if (.isEmpty line)
          (recur b)
          (recur (command/execute b (command/parse line) out)))))))

(defn -main
  [& _]
  (let [in (InputStreamReader. System/in StandardCharsets/UTF_8)
        out (BufferedWriter. (OutputStreamWriter. System/out StandardCharsets/UTF_8)
                             (* 1 1024 1024))]
    (try
      (run in out)
      (.flush out)
      (catch Throwable t
        (.flush out)
        (binding [*out* *err*]
          (println "textbuffer:" (or (ex-message t) (str t))))
        (System/exit 1)))
    (shutdown-agents)
    (System/exit 0)))
