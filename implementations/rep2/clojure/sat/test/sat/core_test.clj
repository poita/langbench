(ns sat.core-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [sat.core :as sat]))

(defn- brute-force-sat?
  "Reference decision procedure: tries all 2^n assignments."
  [n clauses]
  (boolean
   (some (fn [bits]
           (every? (fn [c] (some (fn [l] (= (pos? l) (bit-test bits (dec (Math/abs (long l)))))) c))
                   clauses))
         (range (bit-shift-left 1 n)))))

(defn- php
  "Pigeonhole formula: p+1 pigeons into p holes (unsatisfiable)."
  [p]
  (let [v (fn [i j] (+ (* i p) j 1))]
    (concat (for [i (range (inc p))] (for [j (range p)] (v i j)))
            (for [j (range p) i (range (inc p)) k (range (inc i) (inc p))]
              [(- (v i j)) (- (v k j))]))))

(deftest trivial-formulas
  (is (= :sat (:status (sat/solve 0 []))))
  (is (= [] (:model (sat/solve 0 []))))
  (is (= :unsat (:status (sat/solve 1 [[]]))))
  (is (= :unsat (:status (sat/solve [[1] [-1]]))))
  (is (= :sat (:status (sat/solve [[1 -1]]))))
  (is (= [1 2 3 4 5] (map #(Math/abs (long %)) (:model (sat/solve 5 [[1]])))))
  (is (= 1 (first (:model (sat/solve 5 [[1]])))))
  (testing "unused variables are still assigned"
    (is (= 4 (count (:model (sat/solve 4 [[2]])))))))

(deftest simplification
  (is (= :sat (:status (sat/solve [[1 1 -2] [2 2] [-1 -1 2]]))))
  (is (= :unsat (:status (sat/solve [[1 2] [-1 2] [-1 -2] [1 -2]])))))

(deftest model-is-valid
  (let [cs [[1 -2] [2 3] [-1 -3 4] [-4 2]]
        {:keys [status model]} (sat/solve cs)]
    (is (= :sat status))
    (is (sat/satisfies? model cs))))

(deftest literal-out-of-range
  (is (thrown? clojure.lang.ExceptionInfo (sat/solve 2 [[3]])))
  (is (thrown? clojure.lang.ExceptionInfo (sat/solve 2 [[0]]))))

(deftest pigeonhole
  (is (not (sat/satisfiable? (php 5))))
  (is (not (sat/satisfiable? (php 6)))))

(deftest learns-and-restarts-on-hard-instances
  (let [r (sat/solve (php 7))]
    (is (= :unsat (:status r)))
    (is (pos? (:conflicts (:stats r))))))

(def ^:private gen-formula
  (gen/let [n (gen/choose 1 8)
            cs (gen/vector (gen/vector (gen/let [v (gen/choose 1 n) s gen/boolean]
                                         (if s v (- v)))
                                       0 4)
                           0 40)]
    {:n n :clauses cs}))

(defspec agrees-with-brute-force 300
  (prop/for-all [{:keys [n clauses]} gen-formula]
    (let [{:keys [status model]} (sat/solve n clauses)
          expected (brute-force-sat? n clauses)]
      (and (= expected (= status :sat))
           (or (= status :unsat)
               (and (= n (count model)) (sat/satisfies? model clauses)))))))

(defspec dense-3sat-agrees-with-brute-force 100
  (prop/for-all [cs (gen/vector (gen/vector (gen/let [v (gen/choose 1 10) s gen/boolean]
                                              (if s v (- v)))
                                            3)
                                30 55)]
    (let [{:keys [status model]} (sat/solve 10 cs)]
      (and (= (brute-force-sat? 10 cs) (= status :sat))
           (or (= status :unsat) (sat/satisfies? model cs))))))
