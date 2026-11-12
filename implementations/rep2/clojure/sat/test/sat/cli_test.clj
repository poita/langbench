(ns sat.cli-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is]]
            [sat.cli :as cli]
            [sat.core :as sat]
            [sat.dimacs :as dimacs]))

(defn- run-cli [input]
  (let [out (java.io.StringWriter.)]
    (cli/run (java.io.StringReader. input) out)
    (str out)))

(deftest unsat-output
  (is (= "UNSAT\n" (run-cli "p cnf 2 4\n1 2\n0 -1 2 0\n-1 -2 0 1 -2 0"))))

(deftest empty-formula-output
  (is (= "SAT\n0\n" (run-cli "p cnf 0 0\n"))))

(deftest sat-output-format
  (let [input "c example\np cnf 3 2\n1 -2 0\n2 3 0\n"
        [verdict model & more] (str/split-lines (run-cli input))
        lits (map parse-long (str/split model #" "))]
    (is (= "SAT" verdict))
    (is (empty? more))
    (is (= [1 2 3] (map #(Math/abs (long %)) (butlast lits))))
    (is (= 0 (last lits)))
    (is (sat/satisfies? lits (:clauses (dimacs/parse input))))))

(deftest empty-clause-is-unsat
  (is (= "UNSAT\n" (run-cli "p cnf 2 2\n1 2 0\n0\n"))))
