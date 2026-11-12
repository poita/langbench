(ns scheme.main
  "Command-line tool: read a Scheme program on stdin, write its output on
  stdout. Always exits 0 for programs that run, including ones that end in a
  Scheme runtime error (which is reported in the output)."
  (:require [scheme.core :as core]
            [scheme.reader :as reader])
  (:import [java.io BufferedWriter OutputStreamWriter])
  (:gen-class))

(set! *warn-on-reflection* true)

(defn -main [& _args]
  (let [src (String. (.readAllBytes System/in) "UTF-8")
        out (BufferedWriter. (OutputStreamWriter. System/out "UTF-8") 65536)
        status (try
                 (core/run-program-big-stack src out)
                 0
                 (catch clojure.lang.ExceptionInfo e
                   (if (reader/syntax-error? e)
                     (do (.write out "error: syntax-error\n") 0)
                     (throw e)))
                 (catch StackOverflowError _
                   (.write out "error: stack-overflow\n")
                   0))]
    (.flush out)
    (System/exit status)))
