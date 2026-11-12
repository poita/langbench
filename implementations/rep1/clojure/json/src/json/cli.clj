(ns json.cli
  "Command-line front end: reads one JSON document from stdin and writes its
  canonical serialization (or the line `invalid`) to stdout. The exit status
  is 0 in both cases."
  (:require [json.core :as json])
  (:import (java.io InputStream OutputStream))
  (:gen-class))

(set! *warn-on-reflection* true)

(def ^:private invalid-line
  (.getBytes "invalid\n" java.nio.charset.StandardCharsets/UTF_8))

(defn run
  "Reads the whole of `in`, writes one output line to `out` and flushes it."
  [^InputStream in ^OutputStream out]
  (let [^bytes result
        (try
          (let [^bytes body (json/canonicalize-bytes in)
                line (byte-array (inc (alength body)))]
            (System/arraycopy body 0 line 0 (alength body))
            (aset line (alength body) (byte 10))
            line)
          (catch clojure.lang.ExceptionInfo e
            (if (json/invalid? e) invalid-line (throw e))))]
    (.write out result)
    (.flush out)))

(defn -main
  [& _args]
  (run System/in System/out))
