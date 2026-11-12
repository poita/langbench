(ns template.main
  "Command-line entry point: reads the program text on stdin, prints the
  rendering (or a single `error: <kind>` line) on stdout."
  (:gen-class)
  (:require [template.core :as core]
            [template.errors :as err])
  (:import (java.io PrintStream)
           (java.nio.charset StandardCharsets)))

(defn process
  "Render the program text `input`; returns the full stdout text."
  ^String [^String input]
  (try
    (str (core/render-input input) "\n")
    (catch clojure.lang.ExceptionInfo e
      (if-let [kind (err/error-kind e)]
        (str "error: " (name kind) "\n")
        (throw e)))))

(defn- run []
  (let [input (String. (.readAllBytes System/in) StandardCharsets/UTF_8)
        out (process input)
        ^PrintStream stdout System/out]
    (.write stdout (.getBytes out StandardCharsets/UTF_8))
    (.flush stdout)))

(defn -main
  [& _]
  (let [failure (volatile! nil)
        ;; deep templates recurse deeply: run on a thread with a large stack
        t (Thread. nil
                   (fn [] (try (run) (catch Throwable e (vreset! failure e))))
                   "template-main"
                   (* 1024 1024 1024))]
    (.start t)
    (.join t)
    (if-let [e @failure]
      (do (.printStackTrace ^Throwable e) (System/exit 1))
      (System/exit 0))))
