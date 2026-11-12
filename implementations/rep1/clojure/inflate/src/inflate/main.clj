(ns inflate.main
  "Command-line tool: hex-encoded raw DEFLATE stream on stdin, hex-encoded
  decompressed bytes (or the word `error`) on stdout."
  (:require [inflate.core :as core]
            [inflate.hex :as hex])
  (:gen-class))

(set! *warn-on-reflection* true)

(defn run
  "Reads all of `in`, writes the single result line to `out`."
  [^java.io.InputStream in ^java.io.OutputStream out]
  (let [^bytes result
        (try
          (hex/encode-ascii (core/inflate (hex/decode-ascii (.readAllBytes in))))
          (catch clojure.lang.ExceptionInfo e
            (if (core/malformed? e) (.getBytes "error" "US-ASCII") (throw e))))]
    (.write out result 0 (alength result))
    (.write out 10)
    (.flush out)))

(defn -main [& _]
  (run System/in (java.io.BufferedOutputStream. System/out 65536)))
