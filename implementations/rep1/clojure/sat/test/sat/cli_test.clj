(ns sat.cli-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.string :as str]
            [sat.cli :as cli])
  (:import [java.io StringReader]))

(defn- run [s] (cli/run (StringReader. s)))

(deftest unsat-output
  (is (= "UNSAT\n" (run "p cnf 1 2\n1 0\n-1 0\n")))
  (is (= "UNSAT\n" (run "p cnf 2 1\n0\n"))))

(deftest empty-formula
  (is (= "SAT\n0\n" (run "p cnf 0 0"))))

(deftest model-line-format
  (let [[head line :as lines] (str/split-lines (run "p cnf 4 1\n-1 0\n"))]
    (is (= 2 (count lines)))
    (is (= "SAT" head))
    (let [toks (str/split line #" ")]
      (is (= "0" (last toks)))
      (is (= ["1" "2" "3" "4"] (map #(str/replace % "-" "") (butlast toks))))
      (is (= "-1" (first toks))))))
