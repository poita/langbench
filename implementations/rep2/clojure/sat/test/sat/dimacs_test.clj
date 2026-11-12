(ns sat.dimacs-test
  (:require [clojure.test :refer [deftest is]]
            [sat.dimacs :as dimacs]))

(deftest parses-header-and-clauses
  (is (= {:num-vars 3 :num-clauses 2 :clauses [[1 -2] [2 3]]}
         (dimacs/parse "c hi\np cnf 3 2\n1 -2 0\n2 3 0\n"))))

(deftest clauses-span-lines-and-share-lines
  (is (= [[1 2] [-1 2] [-1 -2] [1 -2]]
         (:clauses (dimacs/parse "p cnf 2 4\n1 2\n0 -1 2 0\n-1 -2 0 1 -2 0")))))

(deftest comments-blanks-and-indentation
  (is (= [[1 -2 3] []]
         (:clauses (dimacs/parse "\n  \t c indented\ncfoo\np  cnf\t3   2\n 1 \t-2\nc mid-clause comment\n  3 0\n\n0\nc end")))))

(deftest empty-formulas
  (is (= {:num-vars 0 :num-clauses 0 :clauses []} (dimacs/parse "p cnf 0 0")))
  (is (= [[]] (:clauses (dimacs/parse "p cnf 1 1\n0\n")))))

(deftest formats-results
  (is (= "UNSAT\n" (dimacs/format-result {:status :unsat})))
  (is (= "SAT\n-1 2 0\n" (dimacs/format-result {:status :sat :model [-1 2]})))
  (is (= "SAT\n0\n" (dimacs/format-result {:status :sat :model []}))))
