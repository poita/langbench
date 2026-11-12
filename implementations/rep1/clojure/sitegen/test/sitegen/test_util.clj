(ns sitegen.test-util
  "Helpers shared by the test namespaces."
  (:import (java.nio.file Files Path Paths)
           (java.nio.file.attribute FileAttribute)))

(defn temp-dir
  "Creates a fresh temporary directory (below $TMPDIR when set, else the JVM's
  temporary directory) and returns its Path."
  ^Path []
  (let [base (or (System/getenv "TMPDIR") (System/getProperty "java.io.tmpdir"))]
    (Files/createTempDirectory (Paths/get base (make-array String 0)) "sitegen-test"
                               (make-array FileAttribute 0))))

(defn tree
  "A sorted map from relative path to the bytes (as a vector) of every file
  below the directory `dir` (a java.io.File)."
  [^java.io.File dir]
  (into (sorted-map)
        (for [^java.io.File f (file-seq dir) :when (.isFile f)]
          [(str (.relativize (.toPath dir) (.toPath f))) (vec (Files/readAllBytes (.toPath f)))])))
