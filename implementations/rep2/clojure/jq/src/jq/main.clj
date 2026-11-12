(ns jq.main
  "Command-line tool. Reads the filter (first line) and the JSON document
  (the rest) from stdin and prints each result as a compact JSON line. On a
  runtime error prints the results so far and then a line `error`."
  (:gen-class)
  (:require [jq.core :as jq]
            [jq.error :as err]
            [jq.json :as json])
  (:import (java.io BufferedOutputStream FileDescriptor FileOutputStream InputStream)
           (java.nio.charset StandardCharsets)))

(set! *warn-on-reflection* true)

(def usage
  "Usage: jq.main < input
  The first line of stdin is a jq filter; the rest is one JSON document.
  Each result is printed as one line of compact JSON. If evaluation fails,
  the results so far are printed, then a line `error`.")

(defn split-input
  "Splits the stdin bytes at the first newline into [filter-text document-text]."
  [^bytes data]
  (let [n (alength data)
        i (loop [i 0] (cond (>= i n) n (== (aget data i) 10) i :else (recur (inc i))))
        filter-text (String. data 0 (int i) StandardCharsets/UTF_8)
        doc-start (min n (inc i))
        doc-text (String. data (int doc-start) (int (- n doc-start)) StandardCharsets/UTF_8)]
    [filter-text doc-text]))

(defn- run-stdin [^BufferedOutputStream out]
  (let [sb (StringBuilder.)
        flush! (fn []
                 (when (pos? (.length sb))
                   (.write out (.getBytes (str sb) StandardCharsets/UTF_8))
                   (.setLength sb 0)))
        emit-line (fn [x]
                    (json/write sb x)
                    (.append sb \newline)
                    (when (> (.length sb) 65536) (flush!)))]
    (try
      (let [[filter-text doc-text] (split-input (.readAllBytes ^InputStream System/in))
            f (jq/compile-filter filter-text)
            doc (jq/parse-json doc-text)]
        (try
          (f doc emit-line)
          (catch clojure.lang.ExceptionInfo e
            (if (err/jq-error? e)
              (.append sb "error\n")
              (throw e)))))
      (catch Throwable t
        (.println System/err (str "jq: " (.getMessage t)))
        (.append sb "error\n")))
    (flush!)
    (.flush out)))

(defn -main
  [& args]
  (if (some #{"-h" "--help"} args)
    (println usage)
    (let [out (BufferedOutputStream. (FileOutputStream. FileDescriptor/out) 65536)
          ;; deeply nested filters/documents: run on a thread with a big stack
          worker (Thread. nil #(run-stdin out) "jq-main" (* 512 1024 1024))]
      (.start worker)
      (.join worker)))
  (shutdown-agents))
