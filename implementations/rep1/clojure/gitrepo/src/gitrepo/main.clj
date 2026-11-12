(ns gitrepo.main
  "Command-line tool: `gitrepo <input path> <output dir>`.

  `<input path>/repo` is a git directory and `<input path>/commands.txt` holds
  one query per line; the answer to line k goes to `<output dir>/NNN.out`.
  A query that fails writes `error`. See SPEC.md."
  (:gen-class)
  (:require [clojure.string :as str]
            [gitrepo.command :as command]
            [gitrepo.core :as core])
  (:import [java.io File]
           [java.nio.file Files]
           [java.nio.charset StandardCharsets]))

(set! *warn-on-reflection* true)

(def ^:private error-output (.getBytes "error\n" StandardCharsets/UTF_8))

(defn read-commands
  "The command lines of `file` (UTF-8, LF-separated); [] when it is absent."
  [^File file]
  (if-not (.isFile file)
    []
    (let [lines (str/split (String. (Files/readAllBytes (.toPath file)) StandardCharsets/UTF_8)
                           #"\n" -1)]
      (if (= "" (peek lines)) (pop lines) lines))))

(defn out-name
  "The output file name for the 1-based command number `k`."
  [k]
  (format "%03d.out" k))

(defn run
  "Answers every command of `<input>/commands.txt` against `<input>/repo`,
  writing `<output>/NNN.out` files."
  [input output]
  (let [out-dir (File. ^String output)
        repo (try (core/open-repo (File. (File. ^String input) "repo"))
                  (catch Throwable _ nil))]
    (.mkdirs out-dir)
    (doseq [[i line] (map-indexed vector (read-commands (File. (File. ^String input) "commands.txt")))]
      (let [result (try (if repo (command/execute repo line) error-output)
                        (catch Throwable _ error-output))]
        (Files/write (.toPath (File. out-dir ^String (out-name (inc i)))) ^bytes result
                     ^"[Ljava.nio.file.OpenOption;" (into-array java.nio.file.OpenOption []))))))

(defn -main [& args]
  (if (= 2 (count args))
    (do (run (first args) (second args))
        (shutdown-agents))
    (do (binding [*out* *err*] (println "usage: gitrepo <input path> <output dir>"))
        (System/exit 2))))
