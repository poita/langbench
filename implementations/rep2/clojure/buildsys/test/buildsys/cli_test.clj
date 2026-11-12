(ns buildsys.cli-test
  "The command-line contract: `<input dir> <output dir>`."
  (:require [buildsys.core :as kiln]
            [clojure.java.io :as io]
            [clojure.test :refer [deftest is]])
  (:import (java.nio.file Files)
           (java.nio.file.attribute FileAttribute)))

(defn- temp-dir [prefix]
  ;; honour $TMPDIR (the JVM's own default can differ, e.g. in sandboxes)
  (let [base (or (System/getenv "TMPDIR") (System/getProperty "java.io.tmpdir"))]
    (str (Files/createTempDirectory (.toPath (io/file base)) prefix (make-array FileAttribute 0)))))

(deftest run-directory-writes-log-and-workspace
  (let [in (temp-dir "kiln-in") out (temp-dir "kiln-out")]
    (.mkdirs (io/file in "src"))
    (spit (io/file in "session.txt") "build\nclean\nbuild\n")
    (spit (io/file in "src" "a.txt") "café\n")
    (spit (io/file in "main.kiln")
          (str "step {\n out \"out/a.txt\"\n in \"src/a.txt\"\n cmd upper()\n}\ndefault \"out/a.txt\"\n"))
    (kiln/run-directory in out)
    (is (.startsWith ^String (slurp (io/file out "log.txt")) "step 1: build (default) -j 1\n"))
    (is (= "CAFé\n" (slurp (io/file out "workspace" "out" "a.txt")))
        "bytes >= 0x80 pass through `upper` untouched")
    (is (not (.exists (io/file out "workspace" "session.txt"))))
    (is (.exists (io/file out "workspace" ".kiln-state")))))
