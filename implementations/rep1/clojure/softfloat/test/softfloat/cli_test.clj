(ns softfloat.cli-test
  (:require [clojure.test :refer [deftest is]]
            [softfloat.cli :as cli])
  (:import (java.io BufferedReader StringReader StringWriter)))

(defn- run [^String input]
  (let [out (StringWriter.)]
    (cli/process (BufferedReader. (StringReader. input)) (StringBuilder.) out)
    (str out)))

(deftest process-lines
  (is (= "40000000\n00000000\nc1100000\n3eaaaaab\n3fb504f3\n"
         (run (str "add 3f800000 3f800000\n"
                   "sub 3f800000 3f800000\n"
                   "mul 40400000 c0400000\n"
                   "div 3f800000 40400000\n"
                   "sqrt 40000000\n")))))

(deftest no-trailing-newline
  (is (= "7fc00000\n" (run "add 7fc12345 3f800000"))))
