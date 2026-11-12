(ns depresolve.cli-test
  (:require [clojure.test :refer [deftest is]])
  (:import (java.io File)))

(defn- run-cli
  "Runs the CLI in a fresh JVM on the current classpath; returns [exit out]."
  [^String input]
  (let [java (str (System/getProperty "java.home") File/separator "bin" File/separator "java")
        pb   (doto (ProcessBuilder. ^java.util.List [java "-cp" (System/getProperty "java.class.path")
                                                    "clojure.main" "-m" "depresolve.cli"])
               (.redirectError java.lang.ProcessBuilder$Redirect/DISCARD))
        p    (.start pb)]
    (with-open [w (.getOutputStream p)]
      (.write w (.getBytes input "UTF-8")))
    (let [out (String. (.readAllBytes (.getInputStream p)) "UTF-8")]
      [(.waitFor p) out])))

(deftest resolves-from-stdin
  (is (= [0 "a 1.0.0\nb 2.0.0\n"]
         (run-cli "a 1.0.0: b ^2.0.0\nb 2.0.0:\nb 1.0.0:\nroot: a *\n"))))

(deftest unsatisfiable-exits-zero
  (is (= [0 "unsatisfiable\n"] (run-cli "root: nope *\n"))))

(deftest empty-resolution-prints-nothing
  (is (= [0 ""] (run-cli "root:\n"))))
