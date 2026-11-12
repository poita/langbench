(ns webhooks.cli
  "Command-line entry point: reads commands from stdin, writes results to
  stdout. See README.md for the protocol."
  (:require [clojure.string :as str]
            [webhooks.bytes :as bytes]
            [webhooks.commands :as commands])
  (:import (java.io BufferedOutputStream)
           (java.nio.charset StandardCharsets))
  (:gen-class))

(set! *warn-on-reflection* true)

(defn blank?
  "True for an empty line or one consisting only of spaces."
  [^String line]
  (every? #(= \space %) line))

(defn read-lines
  "All non-blank lines of `bs`, a byte array of LF-separated text."
  [^bytes bs]
  (->> (str/split (bytes/latin1-string bs) #"\n" -1)
       (remove blank?)))

(defn -main [& _]
  (let [lines (read-lines (.readAllBytes System/in))
        out (BufferedOutputStream. System/out 65536)]
    (doseq [result (commands/process lines)]
      (.write out (.getBytes ^String result StandardCharsets/ISO_8859_1))
      (.write out 10))
    (.flush out)
    (shutdown-agents)
    (System/exit 0)))
