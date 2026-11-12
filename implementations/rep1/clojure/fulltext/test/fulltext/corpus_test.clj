(ns fulltext.corpus-test
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.test :refer [deftest is]]
            [fulltext.corpus :as corpus])
  (:import (java.nio.file Files)
           (java.nio.file.attribute FileAttribute)))

(deftest query-file-parsing
  (is (= [{:number 1 :text "cat dog" :k 10}
          {:number 2 :text "\"a b\"" :k 3}
          {:number 3 :text "last" :k 7}]
         (corpus/parse-queries
          (str "  cat dog \n\n# comment\n%k 3\n\"a b\"\n%k\t7 \n last ")))))

(deftest k-directive-shape
  (is (= [{:number 1 :text "%k" :k 10} {:number 2 :text "%k x" :k 10}
          {:number 3 :text "%k3" :k 10}]
         (corpus/parse-queries "%k\n%k x\n%k3\n"))))

(deftest reading-docs
  (let [dir (Files/createTempDirectory "ft-corpus" (make-array FileAttribute 0))
        docs (io/file (.toFile dir) "docs")]
    (.mkdirs docs)
    (spit (io/file docs "a.txt") "Alpha\r\nbeta ")
    (spit (io/file docs "b.md") "ignored")
    (.mkdirs (io/file docs "sub.txt"))
    (is (= {"a" "Alpha\r\nbeta "} (corpus/read-docs (str (.toFile dir)))))
    (is (= {} (corpus/read-docs (str (io/file (.toFile dir) "nothing")))))))
