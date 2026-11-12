(ns softfloat.cli
  "Command-line front end.

  Reads operations from standard input, one per line (`add a b`, `sub a b`,
  `mul a b`, `div a b`, `sqrt a`, operands as 8 hex digits), and writes the
  result pattern of each as 8 hex digits, one per line, in order."
  (:gen-class)
  (:require [clojure.string :as str]
            [softfloat.core :as core]
            [softfloat.hex :as hex])
  (:import (java.io BufferedReader InputStreamReader PrintStream BufferedOutputStream FileOutputStream FileDescriptor)
           (java.nio.charset StandardCharsets)))

(set! *warn-on-reflection* true)

(defn eval-line
  "Evaluate one input line, returning the result pattern."
  ^long [^String line]
  (let [parts (str/split (str/trim line) #" ")
        op    (first parts)]
    (core/eval-op op (mapv hex/parse (rest parts)))))

(defn process
  "Read lines from `rdr` and write one result line per non-empty input line
  to `out` (an Appendable such as a StringBuilder or Writer)."
  [^BufferedReader rdr ^StringBuilder sb ^java.io.Writer out]
  (loop []
    (when-let [line (.readLine rdr)]
      (when-not (str/blank? line)
        (hex/append-hex8! sb (eval-line line))
        (.append sb \newline)
        (when (> (.length sb) 65536)
          (.write out (str sb))
          (.setLength sb 0)))
      (recur)))
  (.write out (str sb))
  (.flush out))

(defn -main
  "Entry point: stdin -> stdout."
  [& _args]
  (let [rdr (BufferedReader. (InputStreamReader. System/in StandardCharsets/UTF_8) 65536)
        out (java.io.OutputStreamWriter. (BufferedOutputStream. (FileOutputStream. FileDescriptor/out) 65536)
                                         StandardCharsets/UTF_8)]
    (try
      (process rdr (StringBuilder.) out)
      (catch Exception e
        (binding [*out* *err*] (println "softfloat:" (.getMessage e)))
        (System/exit 1)))
    (shutdown-agents)))
