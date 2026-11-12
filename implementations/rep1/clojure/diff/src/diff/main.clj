(ns diff.main
  "Command-line entry point: reads a `diff` or `patch` request on stdin and
  writes the response to stdout."
  (:require [diff.core :as core]
            [diff.io :as dio]
            [diff.script :as script])
  (:gen-class))

(defn run
  "Processes the request text and returns the response text."
  [^String text]
  (let [{:keys [mode a b script]} (dio/parse-request text)]
    (case mode
      :diff (dio/render-response (core/format-script (core/diff a b)))
      :patch (dio/render-response (core/patch a script)))))

(defn -main [& _]
  (try
    (dio/write-text System/out (run (dio/read-all-text System/in)))
    (shutdown-agents)
    (catch Throwable t
      (binding [*out* *err*]
        (println "error:" (.getMessage t)))
      (System/exit 1))))
