(ns bigint.cli
  "Command-line front end: reads queries `<a> <op> <b>` from stdin, one per
  line, and writes one result line per query to stdout.

  Operators: + - * / % ^ cmp. Division/remainder by zero and a negative
  exponent print `error`."
  (:require [bigint.core :as bi])
  (:import (java.io BufferedReader BufferedWriter InputStreamReader
                    OutputStreamWriter Reader Writer))
  (:gen-class))

(set! *warn-on-reflection* true)

(defn- apply-op
  "Applies operator string `op` to BigInts a and b. Returns the result as a
  string, or nil for the error cases."
  [^String op a b]
  (case op
    "+" (bi/->string (bi/add a b))
    "-" (bi/->string (bi/sub a b))
    "*" (bi/->string (bi/mul a b))
    "/" (when-not (bi/zero? b) (bi/->string (bi/quot a b)))
    "%" (when-not (bi/zero? b) (bi/->string (bi/rem a b)))
    "^" (when-not (bi/neg? b) (bi/->string (bi/pow a b)))
    "cmp" (str (bi/compare a b))))

(defn evaluate
  "Evaluates one query line, returning the output line (without newline):
  the canonical result, or \"error\"."
  ^String [^String line]
  (let [i (.indexOf line " ")
        j (.indexOf line " " (int (inc i)))
        a (bi/parse (subs line 0 i))
        op (subs line (inc i) j)
        b (bi/parse (subs line (inc j)))]
    (or (apply-op op a b) "error")))

(defn run
  "Reads queries from Reader `in`, writes results to Writer `out`."
  [^Reader in ^Writer out]
  (let [r (BufferedReader. in)]
    (loop []
      (when-let [line (.readLine r)]
        (.write out (evaluate line))
        (.write out "\n")
        (recur)))
    (.flush out)))

(defn -main [& _]
  (let [in (InputStreamReader. System/in "UTF-8")
        out (BufferedWriter. (OutputStreamWriter. System/out "UTF-8") 65536)]
    (run in out)
    (shutdown-agents)))
