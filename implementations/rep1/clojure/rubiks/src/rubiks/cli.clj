(ns rubiks.cli
  "Command-line interface.

  Reads scrambles from standard input, one per line (space-separated move
  tokens; an empty line is the empty scramble), and prints one solution per
  line to standard output. See the README for details."
  (:require [clojure.string :as str]
            [rubiks.moves :as moves]
            [rubiks.solver :as solver]
            [rubiks.tables :as tables])
  (:import (java.io BufferedWriter OutputStreamWriter)
           (java.nio.charset StandardCharsets)))

(defn solve-line
  "The solution line (space-separated tokens) for one scramble line."
  [phase-tables line]
  (moves/unparse (solver/solve-scramble phase-tables (moves/parse line))))

(defn split-lines
  "Split input text into scramble lines: a final newline terminates the last
  line rather than starting another one, so `\"R\\n\"` and `\"R\"` are one
  scramble and `\"R\\n\\n\"` is two."
  [text]
  (let [lines (str/split text #"\n" -1)]
    (if (str/ends-with? text "\n") (pop lines) lines)))

(defn solve-text
  "Solve every scramble in `text`, returning the output text."
  [phase-tables text]
  (let [out (StringBuilder.)]
    (doseq [sol (pmap #(mapv (partial solve-line phase-tables) %)
                      (partition-all 32 (split-lines text)))
            line sol]
      (.append out ^String line)
      (.append out \newline))
    (str out)))

(defn -main
  "Entry point: `clojure -M -m rubiks.cli < input > output`."
  [& _args]
  (try
    (let [text (slurp System/in :encoding "UTF-8")
          out  (BufferedWriter. (OutputStreamWriter. System/out StandardCharsets/UTF_8))
          tbls @tables/default-tables]
      (.write out ^String (solve-text tbls text))
      (.flush out))
    (catch Exception e
      ;; errors raised on pmap worker threads arrive wrapped in an ExecutionException
      (let [cause (or (->> (iterate ex-cause e) (take-while some?)
                           (filter #(instance? clojure.lang.ExceptionInfo %)) first)
                      e)]
        (binding [*out* *err*] (println "error:" (ex-message cause)))
        (shutdown-agents)
        (System/exit 1))))
  (shutdown-agents)
  (System/exit 0))
