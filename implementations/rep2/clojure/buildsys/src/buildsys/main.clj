(ns buildsys.main
  "Command-line entry point: `buildsys <input directory> <output directory>`."
  (:require [buildsys.core :as core])
  (:gen-class))

(defn run
  "Runs the CLI contract; returns the process exit code."
  [args]
  (if (= 2 (count args))
    (try (core/run-directory (first args) (second args))
         0
         (catch Throwable t
           (binding [*out* *err*] (println "buildsys: internal error:" (.toString t)) (.printStackTrace t))
           1))
    (do (binding [*out* *err*] (println "usage: buildsys <input directory> <output directory>"))
        2)))

(defn -main [& args]
  ;; Deeply nested input needs a deep stack, so run on a thread with a big one.
  (let [code (volatile! 1)
        t (Thread. nil #(vreset! code (run args)) "buildsys" (* 512 1024 1024))]
    (.start t)
    (.join t)
    (shutdown-agents)
    (System/exit @code)))
