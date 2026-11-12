(ns sat.dimacs-test
  (:require [clojure.test :refer [deftest is testing]]
            [sat.dimacs :as dimacs]))

(deftest simple
  (is (= {:num-vars 3 :clauses [[1 -2] [2 3]]}
         (dimacs/parse "c hello\np cnf 3 2\n1 -2 0\n2 3 0\n"))))

(deftest clauses-span-lines-and-share-lines
  (is (= [[1 2] [-1 2] [-1 -2] [1 -2]]
         (:clauses (dimacs/parse "p cnf 2 4\n1 2\n0 -1 2 0\n-1 -2 0 1 -2 0")))))

(deftest comments-and-blanks-anywhere
  (is (= {:num-vars 2 :clauses [[1 2]]}
         (dimacs/parse "  \n\tc x\ncfoo\n  p   cnf\t2  1  \n1\nc between\n\n  2 0\nc after\n"))))

(deftest empty-clauses-and-repeats
  (is (= [[] [1 1 -2] [1 -1]]
         (:clauses (dimacs/parse "p cnf 2 3\n0\n1 1 -2 0 1 -1 0")))))

(deftest no-clauses
  (is (= {:num-vars 0 :clauses []} (dimacs/parse "p cnf 0 0"))))

(deftest malformed
  (testing "no header" (is (thrown? clojure.lang.ExceptionInfo (dimacs/parse "1 0\n"))))
  (testing "unterminated" (is (thrown? clojure.lang.ExceptionInfo (dimacs/parse "p cnf 1 1\n1\n"))))
  (testing "garbage" (is (thrown? clojure.lang.ExceptionInfo (dimacs/parse "p cnf 1 1\nx 0\n")))))

(deftest formatting
  (is (= "UNSAT\n" (dimacs/format-result {:status :unsat})))
  (is (= "SAT\n1 -2 3 0\n" (dimacs/format-result {:status :sat :model [1 -2 3]})))
  (is (= "SAT\n0\n" (dimacs/format-result {:status :sat :model []}))))
