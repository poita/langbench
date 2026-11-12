(ns rubiks.solver-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [rubiks.cubie :as cubie]
            [rubiks.facelet :as facelet]
            [rubiks.moves :as moves]
            [rubiks.moves-test :refer [gen-token]]
            [rubiks.solver :as solver]))

(defn solves?
  "True if applying `solution` after `scramble` leaves a solved cube, checked
  on the independent facelet model."
  [scramble solution]
  (facelet/solved? (facelet/apply-moves facelet/solved (concat scramble solution))))

(def superflip (moves/parse "U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2"))

(deftest trivial-scrambles-test
  (is (= [] (solver/solve-scramble [])))
  (is (= [] (solver/solve-scramble ["R" "R'"])))
  (is (= [] (solver/solve-scramble (repeat 4 "U"))))
  (is (= ["R'"] (solver/solve-scramble ["R"])))
  (is (= ["R2"] (solver/solve-scramble ["R2"]))))

(deftest sexy-move-test
  (let [sc (moves/parse "R U R' U' R U R' U' R U R' U' R U R' U' R U R' U' R U R' U'")]
    (is (= [] (solver/solve-scramble sc)))))

(deftest superflip-test
  (let [sol (solver/solve-scramble superflip)]
    (is (<= (count sol) 45))
    (is (solves? superflip sol))))

(deftest every-single-move-test
  (doseq [t moves/tokens]
    (is (= 1 (count (solver/solve-scramble [t]))) t)
    (is (solves? [t] (solver/solve-scramble [t])))))

(deftest phase-results-test
  (testing "each phase ends in its subgroup and uses at most its bound"
    (let [sc  (moves/parse "F R U' L2 B D' R2 U F' L D2 B' U2 R F2 D L' U B2 R'")
          ph  (solver/solve-phases (cubie/scramble sc))
          s0  (cubie/scramble sc)
          s1  (cubie/apply-moves s0 (ph 0))
          s2  (cubie/apply-moves s1 (ph 1))
          s3  (cubie/apply-moves s2 (ph 2))
          s4  (cubie/apply-moves s3 (ph 3))]
      (is (every? true? (map #(<= (count %1) %2) ph [7 10 13 15])))
      (is (= (vec (repeat 12 0)) (:eo s1)))
      (is (= (vec (repeat 8 0)) (:co s2)))
      (is (every? #(<= 8 %) (map (:ep s2) [8 9 10 11])))
      (is (= #{1 3 5 7} (set (map (:ep s3) [1 3 5 7]))))
      (is (= #{0 2 4 6} (set (map (:ep s3) [0 2 4 6]))))
      (is (cubie/solved? s4)))))

(deftest unsolvable-test
  (is (thrown? clojure.lang.ExceptionInfo
               (solver/solve (assoc cubie/solved :co [1 0 0 0 0 0 0 0])))))

(deftest solves-from-facelets-test
  (let [sc (moves/parse "R U F2 D' L B")
        s  (cubie/from-facelets (facelet/apply-moves facelet/solved sc))]
    (is (solves? sc (solver/solve s)))))

(defspec random-scrambles-are-solved 40
  (prop/for-all [sc (gen/vector gen-token 0 60)]
    (let [sol (solver/solve-scramble sc)]
      (and (<= (count sol) 45)
           (every? (set moves/tokens) sol)
           (solves? sc sol)))))

(defspec long-random-scrambles-are-solved 10
  (prop/for-all [sc (gen/vector gen-token 200 400)]
    (let [sol (solver/solve-scramble sc)]
      (and (<= (count sol) 45) (solves? sc sol)))))
