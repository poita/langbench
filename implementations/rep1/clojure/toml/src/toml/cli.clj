(ns toml.cli
  "Command-line front end.

  Standard input is a mode line, `decode` or `encode`, followed by the
  document.  In decode mode the document is TOML and the output is its tagged
  JSON, or `error` when it is invalid; in encode mode the document is tagged
  JSON and the output is canonical TOML."
  (:require [toml.core :as toml]
            [toml.encoder :as encoder]
            [toml.error :as error]
            [toml.json :as json])
  (:import (java.io InputStream PrintStream)
           (java.nio.charset StandardCharsets)
           (java.util Arrays))
  (:gen-class))

(set! *warn-on-reflection* true)

(defn- index-of-newline ^long [^bytes bs]
  (loop [i 0]
    (cond (>= i (alength bs)) -1
          (== (aget bs i) 10) i
          :else (recur (unchecked-inc i)))))

(defn run
  "Processes the raw bytes of the whole input and returns the output text."
  ^String [^bytes input]
  (let [nl (index-of-newline input)
        nl (if (neg? nl) (alength input) nl)
        mode (String. input 0 (int nl) StandardCharsets/UTF_8)
        body (Arrays/copyOfRange input (int (min (alength input) (inc nl))) (alength input))]
    (case mode
      "decode" (try (str (json/write-tagged (toml/parse-bytes-tagged body)) "\n")
                    (catch clojure.lang.ExceptionInfo e
                      (if (error/parse-error? e) "error\n" (throw e))))
      "encode" (encoder/encode (json/read-tagged (String. body StandardCharsets/UTF_8)))
      (throw (ex-info (str "unknown mode: " mode) {:mode mode})))))

(defn -main [& _]
  (let [out (PrintStream. (java.io.FileOutputStream. java.io.FileDescriptor/out) false)
        ;; The reader and writer recurse on the nesting depth of the document.
        worker (Thread. nil
                        (fn []
                          (let [input (.readAllBytes ^InputStream System/in)
                                text (run input)]
                            (.write out (.getBytes text StandardCharsets/UTF_8))
                            (.flush out)))
                        "toml-main" (* 1024 1024 1024))]
    (.start worker)
    (.join worker)
    (shutdown-agents)))
