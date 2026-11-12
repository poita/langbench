(ns jsonschema.cli
  "Command-line entry point: reads one JSON document
  `{\"schema\": ..., \"tests\": [{\"data\": ...} ...], \"remotes\": {...}}` on
  stdin and prints `valid` / `invalid` for each test, one per line."
  (:require [jsonschema.core :as core]
            [jsonschema.json :as json])
  (:gen-class))

(set! *warn-on-reflection* true)

(defn run
  "Takes the text of a request document and returns the response text."
  ^String [^String input]
  (let [doc (json/parse input)
        _ (when-not (and (map? doc) (contains? doc "schema") (vector? (get doc "tests")))
            (throw (ex-info "input must be an object with \"schema\" and \"tests\"" {})))
        v (core/validator (get doc "schema") {:remotes (get doc "remotes")})
        sb (StringBuilder.)]
    (doseq [t (get doc "tests")]
      (.append sb (if (core/valid? v (get t "data")) "valid\n" "invalid\n")))
    (.toString sb)))

(defn -main [& _]
  (let [code (try
               (let [input (String. (.readAllBytes System/in) java.nio.charset.StandardCharsets/UTF_8)
                     out (core/with-large-stack (run input))
                     w (java.io.PrintStream. (java.io.FileOutputStream. java.io.FileDescriptor/out) false "UTF-8")]
                 (.print w out)
                 (.flush w)
                 0)
               (catch Throwable e
                 (binding [*out* *err*]
                   (println "error:" (ex-message e)))
                 1))]
    (shutdown-agents)
    (System/exit code)))
