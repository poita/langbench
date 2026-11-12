(ns buildsys.main
  "Command-line entry point: `buildsys <input dir> <output dir>`.

  Reads `session.txt` and the initial workspace from the input directory, runs
  the session, and writes `log.txt` and `workspace/` into the output directory."
  (:require [buildsys.core :as kiln])
  (:import (java.nio.charset StandardCharsets)
           (java.nio.file Files Paths)
           (java.nio.file.attribute FileAttribute))
  (:gen-class))

(defn- path ^java.nio.file.Path [^String first & more]
  (Paths/get first (into-array String more)))

(defn run-session!
  "Run the session found in `in-dir`, writing the results to `out-dir`."
  [^String in-dir ^String out-dir]
  (let [session-text (kiln/bytes->str (Files/readAllBytes (path in-dir "session.txt")))
        ws (kiln/load-workspace in-dir true)
        {:keys [log workspace]} (kiln/run-session ws session-text)]
    (Files/createDirectories (path out-dir) (make-array FileAttribute 0))
    (Files/write (path out-dir "log.txt")
                 (.getBytes ^String log StandardCharsets/ISO_8859_1)
                 (make-array java.nio.file.OpenOption 0))
    (kiln/write-workspace workspace (str (path out-dir "workspace")))))

(defn -main
  [& args]
  (if-not (= 2 (count args))
    (do (binding [*out* *err*]
          (println "usage: buildsys <input directory> <output directory>"))
        (System/exit 2))
    ;; deeply nested build files recurse deeply: run on a thread with a big stack
    (let [failure (volatile! nil)
          t (Thread. nil
                     (fn []
                       (try (run-session! (first args) (second args))
                            (catch Throwable e (vreset! failure e))))
                     "kiln-main"
                     (* 512 1024 1024))]
      (.start t)
      (.join t)
      (if-let [e @failure]
        (do (.printStackTrace ^Throwable e) (System/exit 1))
        (System/exit 0)))))
