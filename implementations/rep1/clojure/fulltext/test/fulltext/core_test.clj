(ns fulltext.core-test
  (:require [clojure.java.io :as io]
            [clojure.test :refer [deftest is]]
            [fulltext.core :as ft])
  (:import (java.nio.file Files)
           (java.nio.file.attribute FileAttribute)))

(defn- temp-dir [prefix]
  (.toFile (Files/createTempDirectory prefix (make-array FileAttribute 0))))

(deftest run-directory-end-to-end
  (let [in (temp-dir "ft-in") out (temp-dir "ft-out")]
    (.mkdirs (io/file in "docs"))
    (spit (io/file in "docs" "note.txt") "The quick brown fox jumps over the lazy dog.\n")
    (spit (io/file in "queries.txt") "fox\nquick brown\ncat\n\"lazy dog\"")
    (ft/run-directory (str in) (str out))
    (is (= (str "QUERY 1 fox\nHITS 1\n1\tnote\t0.2877\tThe quick brown fox jumps over the lazy dog\n"
                "QUERY 2 quick brown\nHITS 1\n1\tnote\t0.5754\tThe quick brown fox jumps over the lazy dog\n"
                "QUERY 3 cat\nHITS 0\n"
                "QUERY 4 \"lazy dog\"\nHITS 1\n1\tnote\t0.2877\tThe quick brown fox jumps over the lazy dog\n")
           (slurp (io/file out "results.txt"))))
    (is (= "documents 1\ntokens 9\nterms 8\navgdl 9.0000\n"
           (slurp (io/file out "stats.txt"))))))

(deftest missing-docs-directory
  (let [in (temp-dir "ft-in") out (temp-dir "ft-out")]
    (spit (io/file in "queries.txt") "anything\n")
    (ft/run-directory (str in) (str out))
    (is (= "QUERY 1 anything\nHITS 0\n" (slurp (io/file out "results.txt"))))
    (is (= "documents 0\ntokens 0\nterms 0\navgdl 0.0000\n" (slurp (io/file out "stats.txt"))))))

(deftest facade
  (is (= "run" (ft/stem "running")))
  (is (= [{:text "dogs" :term "dog"}] (ft/analyze "Dogs")))
  (is (= [:atom ["cat"]] (ft/parse-query "cat")))
  (is (= {:documents 1 :tokens 2 :terms 2 :avgdl 2.0}
         (ft/stats (ft/build-index [["a" "hello world"]])))))
