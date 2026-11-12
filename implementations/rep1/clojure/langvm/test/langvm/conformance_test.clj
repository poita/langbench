(ns langvm.conformance-test
  "Runs the external conformance suite (`NNN_name.in` / `.out` pairs) when it
  is available.  Set LANGVM_TESTS to its directory, or keep the default
  location next to this project."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [langvm.test-util :as u]))

(defn- suite-dir []
  (let [d (io/file (or (System/getenv "LANGVM_TESTS") "../problems/langvm/tests"))]
    (when (.isDirectory d) d)))

(deftest conformance-suite
  (if-let [dir (suite-dir)]
    (doseq [^java.io.File in (sort-by #(.getName ^java.io.File %) (.listFiles dir))
            :when (str/ends-with? (.getName in) ".in")]
      (testing (.getName in)
        (is (u/same-output? (slurp (str/replace (.getPath in) #"\.in$" ".out"))
                            (u/run (slurp in))))))
    (println "conformance suite not found; skipping")))
