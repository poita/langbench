(ns sat.core-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [sat.core :as sat]))

(defn- brute-force-sat?
  "Exhaustively checks satisfiability (for small variable counts)."
  [n clauses]
  (boolean
   (some (fn [bits]
           (let [true-lits (set (map-indexed (fn [i _] (if (bit-test bits i) (inc i) (- (inc i)))) (range n)))]
             (every? (fn [c] (some true-lits c)) clauses)))
         (range (bit-shift-left 1 n)))))

(defn- pigeonhole [holes]
  (let [pigeons (inc holes)
        v (fn [p h] (inc (+ (* p holes) h)))]
    {:num-vars (* pigeons holes)
     :clauses (concat (for [p (range pigeons)] (for [h (range holes)] (v p h)))
                      (for [h (range holes) p1 (range pigeons) p2 (range (inc p1) pigeons)]
                        [(- (v p1 h)) (- (v p2 h))]))}))

(deftest trivial-cases
  (is (= :sat (:status (sat/solve 0 []))))
  (is (= [] (:model (sat/solve 0 []))))
  (is (= :unsat (:status (sat/solve 0 [[]]))))
  (is (= :unsat (:status (sat/solve 3 [[1 2] [] [3]]))))
  (is (= :unsat (:status (sat/solve 1 [[1] [-1]]))))
  (is (= :sat (:status (sat/solve 1 [[1 -1]]))))
  (is (= 5 (count (:model (sat/solve 5 [[1]]))))))

(deftest duplicates-and-tautologies
  (let [clauses [[1 1 -2] [2 2] [-1 1] [3 -3 3]]
        r (sat/solve 3 clauses)]
    (is (= :sat (:status r)))
    (is (sat/satisfies? (:model r) clauses))))

(deftest all-eight-clauses-over-three-variables
  (let [all (for [a [1 -1] b [2 -2] c [3 -3]] [a b c])]
    (is (= :unsat (:status (sat/solve 3 all))))
    (is (= :sat (:status (sat/solve 3 (rest all)))))))

(deftest examples-from-the-spec
  (let [r (sat/solve-dimacs "c t\np cnf 3 2\n1 -2 0\n2 3 0\n")]
    (is (= :sat (:status r)))
    (is (sat/satisfies? (:model r) [[1 -2] [2 3]])))
  (is (= :unsat (:status (sat/solve-dimacs "p cnf 2 4\n1 2\n0 -1 2 0\n-1 -2 0 1 -2 0")))))

(deftest long-clause
  (let [clause (vec (range 1 1001))
        r (sat/solve 1000 [clause])]
    (is (= :sat (:status r)))
    (is (sat/satisfies? (:model r) [clause]))))

(deftest pigeonhole-formulas
  (testing "n+1 pigeons in n holes is unsatisfiable"
    (doseq [h (range 1 7)]
      (let [{:keys [num-vars clauses]} (pigeonhole h)]
        (is (= :unsat (:status (sat/solve num-vars clauses))) (str "PHP " h)))))
  (testing "n pigeons in n holes is satisfiable"
    (let [{:keys [num-vars clauses]} (pigeonhole 5)
          ;; drop the last pigeon's clause and its conflicts: 5 pigeons, 5 holes
          cs (remove (fn [c] (some #(> (Math/abs (long %)) 25) c)) clauses)
          r (sat/solve num-vars cs)]
      (is (= :sat (:status r)))
      (is (sat/satisfies? (:model r) cs)))))

(deftest out-of-range-literal
  (is (thrown? clojure.lang.ExceptionInfo (sat/solve 2 [[3]])))
  (is (thrown? clojure.lang.ExceptionInfo (sat/solve 2 [[0]]))))

(defn- cnf-gen [max-vars max-clauses max-len]
  (gen/bind (gen/choose 1 max-vars)
            (fn [n]
              (gen/fmap (fn [cs] {:n n :clauses cs})
                        (gen/vector
                         (gen/vector (gen/fmap (fn [[v s]] (if s v (- v)))
                                               (gen/tuple (gen/choose 1 n) gen/boolean))
                                     0 max-len)
                         0 max-clauses)))))

(defspec agrees-with-brute-force 300
  (prop/for-all [{:keys [n clauses]} (cnf-gen 8 40 4)]
    (let [r (sat/solve n clauses)]
      (and (= (brute-force-sat? n clauses) (= :sat (:status r)))
           (or (= :unsat (:status r))
               (and (= (range 1 (inc n)) (map #(Math/abs (long %)) (:model r)))
                    (sat/satisfies? (:model r) clauses)))))))

(defn- random-3sat [rnd n m]
  (vec (repeatedly m (fn [] (vec (for [v (take 3 (shuffle (range 1 (inc n))))]
                                   (if (.nextBoolean ^java.util.Random rnd) v (- v))))))))

(deftest random-3sat-near-threshold
  (let [rnd (java.util.Random. 42)]
    (dotimes [_ 6]
      (let [clauses (random-3sat rnd 60 256)
            r (sat/solve 60 clauses)]
        (when (= :sat (:status r))
          (is (sat/satisfies? (:model r) clauses)))
        (is (#{:sat :unsat} (:status r)))))))
