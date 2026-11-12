(ns buildsys.test-util
  "Helpers shared by the test namespaces."
  (:require [buildsys.core :as kiln]
            [clojure.string :as str]))

(defn session-log
  "Runs `session` over `files` and returns the log text."
  [files session]
  (:log (kiln/run-session files session)))

(defn lines
  "Joins `ls` with newlines, adding a final newline."
  [& ls]
  (str (str/join "\n" ls) "\n"))

(defn first-error
  "The error text of the first `build` of `files` (or nil when it succeeds)."
  [main-kiln & {:as opts}]
  (:error (apply kiln/build {"main.kiln" main-kiln} (mapcat identity opts))))
