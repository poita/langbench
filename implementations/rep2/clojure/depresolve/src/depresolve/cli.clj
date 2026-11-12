(ns depresolve.cli
  "Command-line entry point: reads the input on stdin, writes the
  resolution (or `unsatisfiable`) to stdout."
  (:require [depresolve.core :as core])
  (:gen-class))

(set! *warn-on-reflection* true)

(defn -main [& _args]
  (let [input (String. (.readAllBytes System/in) java.nio.charset.StandardCharsets/UTF_8)
        out   (core/resolve-text input)
        w     (java.io.PrintStream. (java.io.FileOutputStream. java.io.FileDescriptor/out) false "UTF-8")]
    (.print w out)
    (.flush w)
    (shutdown-agents)))
