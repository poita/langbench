(ns kvstore.test-util
  "Helpers shared by the test namespaces."
  (:require [clojure.string :as str]
            [kvstore.bytes :as b]
            [kvstore.cli :as cli]))

(defn script
  "Run command lines (a string or a seq of strings) against an optional
  `{:main :wal}` input.  Returns `{:results :main :wal}` (results as a string)."
  ([lines] (script lines nil nil))
  ([lines main wal]
   (cli/run-script (b/utf8 (if (string? lines) lines (str/join "\n" lines))) main wal)))

(defn results
  "The `results.txt` text of a script run."
  [lines]
  (:results (script lines)))

(defn statuses
  "Just the status lines of a script run, without the `[k] ` prefix."
  [lines]
  (->> (str/split-lines (results lines))
       (remove #(str/starts-with? % "  "))
       (mapv #(str/replace-first % #"^\[\d+\] " ""))))

(defn hex-page
  "Page `n` (1-based) of a database image as a hex string."
  [^bytes image n]
  (b/hex (b/sub image (* 1024 (dec n)) (* 1024 n))))
