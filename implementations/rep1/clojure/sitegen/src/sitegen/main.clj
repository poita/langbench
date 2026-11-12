(ns sitegen.main
  "Command-line entry point: `sitegen <input directory> <output directory>`."
  (:gen-class)
  (:require [sitegen.core :as core]))

(defn run
  "Runs the generator for the command-line `args`.  Returns the process exit
  code: 0 on success, 2 on a usage error and 1 when generation fails."
  [args]
  (if (not= 2 (count args))
    (do (binding [*out* *err*]
          (println "usage: sitegen <input directory> <output directory>"))
        2)
    (try
      (core/generate! (first args) (second args))
      0
      (catch Throwable e
        (binding [*out* *err*]
          (println "sitegen: error:" (or (ex-message e) (str e))))
        1))))

(defn -main
  "Runs `run` on a thread with a large stack (deeply nested documents recurse
  deeply) and exits with its result."
  [& args]
  (let [result (volatile! 1)
        t (Thread. nil #(vreset! result (run args)) "sitegen" (* 512 1024 1024))]
    (.start t)
    (.join t)
    (shutdown-agents)
    (System/exit (long @result))))
