(ns commonmark.main
  "Command-line tool: reads Markdown from standard input and writes the HTML to
  standard output (both UTF-8)."
  (:require [commonmark.core :as core])
  (:import (java.io BufferedOutputStream)
           (java.nio.charset StandardCharsets))
  (:gen-class))

(set! *warn-on-reflection* true)

(defn convert-stream
  "Read all of `in` (an InputStream) as UTF-8 Markdown and write the HTML to
  `out` (an OutputStream)."
  [^java.io.InputStream in ^java.io.OutputStream out]
  (let [md (String. (.readAllBytes in) StandardCharsets/UTF_8)
        html (core/markdown->html md)
        out (BufferedOutputStream. out 65536)]
    (.write out (.getBytes ^String html StandardCharsets/UTF_8))
    (.flush out)))

(defn -main
  [& _args]
  ;; Deeply nested input is handled on a thread with a generous stack.
  (let [failure (atom nil)
        worker (Thread. nil
                        (fn []
                          (try (convert-stream System/in System/out)
                               (catch Throwable e (reset! failure e))))
                        "commonmark"
                        (* 512 1024 1024))]
    (.start worker)
    (.join worker)
    (when-let [e @failure]
      (.printStackTrace ^Throwable e)
      (System/exit 1))
    (shutdown-agents)))
