(ns bigint.cli-test
  (:require [bigint.cli :as cli]
            [clojure.test :refer [deftest is]])
  (:import (java.io StringReader StringWriter)))

(defn- run [input]
  (let [out (StringWriter.)]
    (cli/run (StringReader. input) out)
    (str out)))

(deftest empty-input
  (is (= "" (run ""))))

(deftest one-line-per-query
  (is (= "42\n-2\n-3\n-1\n" (run "12 + 30\n5 - 7\n-7 / 2\n-7 % 2\n"))))

(deftest final-newline-is-optional
  (is (= "3\n" (run "1 + 2")))
  (is (= "3\n" (run "1 + 2\n"))))

(deftest errors-do-not-stop-processing
  (is (= "error\n1\nerror\n0\n" (run "1 / 0\n1 ^ 0\n2 ^ -3\n-0 % 5\n"))))

(deftest unicode-input-is-not-needed-but-lines-are-independent
  (is (= "0\n0\n" (run "0 cmp -0\n-000 + 0\n"))))
