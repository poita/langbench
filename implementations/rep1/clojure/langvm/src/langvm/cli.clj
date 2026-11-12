(ns langvm.cli
  "Command-line entry point: read a module stream on stdin, compile and run it
  (SPEC section 1).  Always exits 0."
  (:require [langvm.core :as core])
  (:gen-class))

(defn -main [& _]
  (let [text (String. (.readAllBytes System/in) java.nio.charset.StandardCharsets/UTF_8)
        out (java.io.BufferedOutputStream. System/out 65536)]
    (try
      (core/execute text out)
      (finally (.flush out)))
    (shutdown-agents)
    (System/exit 0)))
