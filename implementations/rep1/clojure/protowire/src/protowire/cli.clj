(ns protowire.cli
  "Command-line entry point: reads a request document on stdin, writes one
  result line per request on stdout. Always exits 0."
  (:require [protowire.core :as core])
  (:import (java.io BufferedOutputStream)
           (java.nio.charset StandardCharsets))
  (:gen-class))

(set! *warn-on-reflection* true)

(defn -main
  [& _args]
  (let [input (String. (.readAllBytes System/in) StandardCharsets/UTF_8)
        output (core/run-requests input)
        out (BufferedOutputStream. System/out 65536)]
    (.write out (.getBytes output StandardCharsets/UTF_8))
    (.flush out)
    (shutdown-agents)
    (System/exit 0)))
