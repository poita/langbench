(ns ordered-map.main
  "Command-line entry point: reads commands on stdin, writes one response
  line per command on stdout."
  (:require [ordered-map.commands :as commands])
  (:import (java.io BufferedOutputStream)
           (java.nio.charset StandardCharsets))
  (:gen-class))

(set! *warn-on-reflection* true)

(defn -main [& _]
  (let [input  (String. (.readAllBytes System/in) StandardCharsets/UTF_8)
        output (commands/run-input input)
        out    (BufferedOutputStream. System/out 65536)]
    (.write out (.getBytes output StandardCharsets/UTF_8))
    (.flush out)
    (shutdown-agents)))
