(ns sqlitefile.cli-test
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [sqlitefile.cli :as cli]
            [sqlitefile.fixture :as fx])
  (:import (java.nio.file Files)
           (java.nio.file.attribute FileAttribute)))

(defn- temp-dir [prefix]
  (let [base (doto (io/file "target/test-tmp") .mkdirs)]
    (.toFile (Files/createTempDirectory (.toPath base) prefix (make-array FileAttribute 0)))))

(defn- run-cli [db-bytes queries-text]
  (let [in (temp-dir "sqlitefile-in") out (temp-dir "sqlitefile-out")]
    (with-open [o (io/output-stream (io/file in "sample.sqlite"))] (.write o ^bytes db-bytes))
    (spit (io/file in "queries.txt") queries-text)
    (cli/process (str in) (str out))
    (into (sorted-map)
          (for [f (.listFiles out)] [(.getName f) (slurp f)]))))

(deftest read-queries-handles-final-newline
  (is (= ["a" "b"] (cli/read-queries "a\nb")))
  (is (= ["a" "b"] (cli/read-queries "a\nb\n"))))

(deftest writes-one-numbered-file-per-query
  (let [out (run-cli (fx/sample-db)
                     (str/join "\n" [".tables" "COUNT people" "SELECT nope FROM people"
                                     "SELECT name FROM people WHERE age IS NULL"
                                     "SELECT name FROM people WHERE age > 99"]))]
    (is (= ["001.txt" "002.txt" "003.txt" "004.txt" "005.txt"] (keys out)))
    (is (= "blobs\npeople\n" (out "001.txt")))
    (is (= "5\n" (out "002.txt")))
    (is (= "error\n" (out "003.txt")))
    (is (= "Alan\n" (out "004.txt")))
    (is (= "" (out "005.txt")))))

(deftest unreadable-database-yields-errors
  (is (= {"001.txt" "error\n"} (run-cli (byte-array 300) "COUNT people"))))
