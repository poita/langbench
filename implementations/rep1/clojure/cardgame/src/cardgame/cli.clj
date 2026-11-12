(ns cardgame.cli
  "Command-line tool: reads a match file on stdin, writes the log on stdout.

      clojure -M -m cardgame.cli < match.txt"
  (:require [cardgame.core :as core])
  (:gen-class))

(defn -main
  [& _]
  (let [text (String. (.readAllBytes System/in) "UTF-8")
        out (core/run-match text)
        ps (java.io.PrintStream. (java.io.FileOutputStream. java.io.FileDescriptor/out) false "UTF-8")]
    (.print ps out)
    (.flush ps)
    (shutdown-agents)))
