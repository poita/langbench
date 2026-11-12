(ns linalg.cli-test
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.test :refer [deftest is]]
            [linalg.cli :as cli])
  (:import (java.nio.file Files)
           (java.nio.file.attribute FileAttribute)))

(defn- temp-dir []
  (let [base (or (System/getenv "TMPDIR") (System/getProperty "java.io.tmpdir"))]
    (.toFile (Files/createTempDirectory (.toPath (io/file base)) "linalg-test"
                                        (make-array FileAttribute 0)))))

(defn- run-script
  "Runs a script against `files` (name -> text); returns name -> text of the
  output directory."
  [commands files]
  (let [in (temp-dir) out (temp-dir)]
    (spit (io/file in "commands.txt") commands)
    (doseq [[n t] files] (spit (io/file in n) t))
    (cli/run-script! in out)
    (into (sorted-map) (for [f (.listFiles out)] [(.getName f) (slurp f)]))))

(def a-mtx "%%MatrixMarket matrix array real general\n2 2\n1.0\n3.0\n2.0\n4.0\n")
(def b-mtx "%%MatrixMarket matrix coordinate real general\n2 2 2\n1 1 0.5\n2 2 -1.5\n")
(def s-mtx "%%MatrixMarket matrix array real symmetric\n2 2\n4.0\n2.0\n5.0\n")
(def r-mtx "%%MatrixMarket matrix array real general\n2 3\n1\n2\n3\n4\n5\n6\n")

(deftest whole-run-from-the-spec
  (let [out (run-script "# a two by two example\nadd a.mtx b.mtx\n\n  det a.mtx\t\nchol s.mtx\n"
                        {"a.mtx" a-mtx "b.mtx" b-mtx "s.mtx" s-mtx})]
    (is (= ["001_add.mtx" "002_det.mtx" "003_chol_L.mtx"] (keys out)))
    (is (= (str "%%MatrixMarket matrix array real general\n2 2\n"
                "1.5000000000e+00\n3.0000000000e+00\n2.0000000000e+00\n2.5000000000e+00\n")
           (out "001_add.mtx")))
    (is (= "%%MatrixMarket matrix array real general\n1 1\n-2.0000000000e+00\n"
           (out "002_det.mtx")))
    (is (= (str "%%MatrixMarket matrix array real general\n2 2\n"
                "2.0000000000e+00\n1.0000000000e+00\n0.0000000000e+00\n2.0000000000e+00\n")
           (out "003_chol_L.mtx")))))

(deftest errors-replace-results-and-do-not-stop-the-script
  (let [out (run-script "chol r.mtx\nsolve r.mtx a.mtx\nmul r.mtx r.mtx\nnorm1 a.mtx\n"
                        {"a.mtx" a-mtx "r.mtx" r-mtx})]
    (is (= ["001_error.txt" "002_error.txt" "003_error.txt" "004_norm1.mtx"] (keys out)))
    (is (= "not_square\n" (out "001_error.txt")))
    (is (= "not_square\n" (out "002_error.txt")))
    (is (= "dimension_mismatch\n" (out "003_error.txt")))))

(deftest multi-file-results
  (let [out (run-script "lu a.mtx\nsvd a.mtx\neig s.mtx\nqr a.mtx\n"
                        {"a.mtx" a-mtx "s.mtx" s-mtx})]
    (is (= ["001_lu_L.mtx" "001_lu_P.mtx" "001_lu_U.mtx"
            "002_svd_S.mtx" "002_svd_U.mtx" "002_svd_V.mtx"
            "003_eig_V.mtx" "003_eig_w.mtx"
            "004_qr_Q.mtx" "004_qr_R.mtx"]
           (keys out)))))

(deftest parse-script-skips-comments-and-blanks
  (is (= [["add" "a" "b"] ["det" "a"]]
         (cli/parse-script "# c\n\n  add \t a   b \n   # x\r\ndet a\n"))))
