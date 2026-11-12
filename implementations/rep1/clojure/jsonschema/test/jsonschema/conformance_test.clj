(ns jsonschema.conformance-test
  "Runs the stdin-mode conformance cases (`NNN_name.in` / `NNN_name.out`) when a
  test directory is available. Set JSONSCHEMA_TESTS to its path; by default
  `../problems/jsonschema/tests` is tried. The test passes vacuously when the
  directory does not exist."
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [jsonschema.cli :as cli]
            [jsonschema.core :as core])
  (:import (java.io File)))

(defn- tests-dir []
  (let [d (File. ^String (or (System/getenv "JSONSCHEMA_TESTS") "../problems/jsonschema/tests"))]
    (when (.isDirectory d) d)))

(defn- normalise [s] (str/trim (str/join "\n" (map str/trimr (str/split-lines s)))))

(deftest conformance-cases
  (if-let [dir (tests-dir)]
    (doseq [^File in (sort-by #(.getName ^File %) (filter #(.endsWith (.getName ^File %) ".in") (.listFiles dir)))]
      (let [out (File. dir (str (subs (.getName in) 0 (- (count (.getName in)) 3)) ".out"))]
        (testing (.getName in)
          (is (= (normalise (slurp out))
                 (normalise (core/with-large-stack (cli/run (slurp in)))))))))
    (println "conformance cases not found; skipping")))
