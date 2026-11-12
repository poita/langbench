(ns orderbook.cli
  "Command-line entry point: reads commands from stdin, writes events to
  stdout.  Usage: `clojure -M:cli < input.txt`."
  (:require [orderbook.stream :as stream])
  (:import (java.io BufferedReader BufferedWriter FileDescriptor
                    FileOutputStream InputStreamReader OutputStreamWriter)
           (java.nio.charset StandardCharsets))
  (:gen-class))

(set! *warn-on-reflection* true)

(defn -main [& _args]
  (let [in (BufferedReader. (InputStreamReader. System/in StandardCharsets/UTF_8) 65536)
        out (BufferedWriter.
             (OutputStreamWriter. (FileOutputStream. FileDescriptor/out)
                                  StandardCharsets/UTF_8)
             65536)]
    (stream/process! in out)
    (.flush out)))
