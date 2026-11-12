(ns jq.cli
  "Command-line front end.

  Reads all of stdin: the first line is the filter, the rest is one JSON
  document. Every result is printed as one line of compact JSON; if
  evaluation fails, the results before the failure are printed, then a line
  `error`. The exit status is 0."
  (:require [jq.core :as jq]
            [jq.json :as json])
  (:import [java.io BufferedWriter OutputStreamWriter Writer])
  (:gen-class))

(defn process
  "Evaluates the program text `text` (filter line, newline, JSON document)
  writing result lines (or a final `error` line) to the Writer `w`."
  [^String text ^Writer w]
  (let [nl (.indexOf text "\n")
        filter-src (if (neg? nl) text (subs text 0 nl))
        doc-src (if (neg? nl) "" (subs text (inc nl)))
        sb (StringBuilder.)]
    (try
      (let [f (jq/compile filter-src)
            doc (json/parse doc-src)]
        (jq/run-each f doc
                     (fn [x]
                       (.setLength sb 0)
                       (json/write-value! sb x)
                       (.append sb \newline)
                       (.write w (.toString sb)))))
      (catch Throwable e
        (when (System/getenv "JQ_DEBUG") (.printStackTrace e))
        (.write w "error\n")))
    (.flush w)))

(defn- run-main []
  (let [text (String. (.readAllBytes System/in) "UTF-8")
        w (BufferedWriter. (OutputStreamWriter. System/out "UTF-8") 65536)]
    (process text w)))

(defn -main
  "Entry point; runs on a thread with a large stack so deeply nested
  documents and filters cannot overflow it."
  [& _args]
  (let [t (Thread. nil run-main "jq-main" (* 512 1024 1024))]
    (.start t)
    (.join t)
    (shutdown-agents)
    (System/exit 0)))
