(ns mime.main
  "Command-line entry point: `mime <input path> <output directory>`."
  (:require [mime.core :as core])
  (:gen-class))

(set! *warn-on-reflection* true)

(defn -main
  [& args]
  (if (= 2 (count args))
    (try
      (core/convert! (first args) (second args))
      (shutdown-agents)
      (System/exit 0)
      (catch Throwable t
        (binding [*out* *err*]
          (println "mime: error:" (.getMessage t)))
        (System/exit 1)))
    (do (binding [*out* *err*]
          (println "usage: mime <input path> <output directory>"))
        (System/exit 2))))
