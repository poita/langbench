(ns orderbook.stream
  "The line-oriented text protocol: a command count, then one command per
  line in; one event per line out (see SPEC.md)."
  (:require [orderbook.command :as command]
            [orderbook.core :as core]
            [orderbook.event :as event])
  (:import (java.io BufferedReader Writer)))

(set! *warn-on-reflection* true)

(defn process!
  "Reads the command count and then that many commands from `in`, executes
  them against a fresh book and writes the events to `out`, each followed by
  a newline.  Does not close or flush either stream."
  [^BufferedReader in ^Writer out]
  (let [book (core/new-book)
        header (.readLine in)
        n (if header (Long/parseLong (.trim header)) 0)
        sink (fn [ev]
               (event/append-event! out ev)
               (.write out 10))]
    (loop [i 0]
      (when (< i n)
        (when-let [line (.readLine in)]
          (core/execute! book (command/parse-line line) sink)
          (recur (inc i)))))))
