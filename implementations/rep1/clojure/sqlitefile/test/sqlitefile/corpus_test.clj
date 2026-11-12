(ns sqlitefile.corpus-test
  "Runs the shared example corpus (`../problems/sqlitefile/tests`) through the
  command-line entry point when it is present next to this project; the test
  is a no-op otherwise."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [sqlitefile.cli :as cli])
  (:import (java.nio.file Files)
           (java.nio.file.attribute FileAttribute)))

(def corpus-dir (io/file "../problems/sqlitefile/tests"))

(defn- normalize [s]
  (str/replace (str/join "\n" (map str/trimr (str/split s #"\n" -1))) #"\n+$" ""))

(deftest corpus
  (when (.isDirectory corpus-dir)
    (doseq [t (sort (.listFiles corpus-dir)) :when (.isDirectory t)]
      (testing (.getName t)
        (let [out (.toFile (Files/createTempDirectory (.toPath (doto (io/file "target/test-tmp") .mkdirs)) "corpus" (make-array FileAttribute 0)))]
          (cli/process (str (io/file t "input")) (str out))
          (doseq [e (.listFiles (io/file t "expected"))]
            (is (= (normalize (slurp e)) (normalize (slurp (io/file out (.getName e)))))
                (str (.getName t) "/" (.getName e)))))))))
