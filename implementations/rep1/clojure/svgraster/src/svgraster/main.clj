(ns svgraster.main
  "Command-line entry point: `svgraster <input-dir> <output-dir>`."
  (:gen-class)
  (:require [svgraster.core :as core]))

(defn -main
  [& args]
  (if (not= 2 (count args))
    (do (binding [*out* *err*]
          (println "usage: svgraster <input-dir> <output-dir>"))
        (System/exit 2))
    (let [failures (atom 0)]
      (try
        (core/render-directory
         (first args) (second args)
         (fn [{:keys [name]} e]
           (swap! failures inc)
           (binding [*out* *err*]
             (println (str name ": " (ex-message e))))))
        (catch Exception e
          (binding [*out* *err*]
            (println (str "svgraster: " (ex-message e))))
          (System/exit 1)))
      (shutdown-agents)
      (System/exit (if (pos? @failures) 1 0)))))
