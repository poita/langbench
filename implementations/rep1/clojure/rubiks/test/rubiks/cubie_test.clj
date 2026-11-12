(ns rubiks.cubie-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [rubiks.cubie :as cubie]
            [rubiks.facelet :as facelet]
            [rubiks.moves :as moves]
            [rubiks.moves-test :refer [gen-tokens]]))

(def superflip (moves/parse "U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2"))

(deftest solved-test
  (is (cubie/solved? cubie/solved))
  (is (cubie/solvable? cubie/solved))
  (is (= facelet/solved (cubie/->facelets cubie/solved)))
  (is (= cubie/solved (cubie/from-facelets facelet/solved))))

(deftest superflip-test
  (let [s (cubie/scramble superflip)]
    (is (= (:cp cubie/solved) (:cp s)))
    (is (= (:co cubie/solved) (:co s)))
    (is (= (:ep cubie/solved) (:ep s)))
    (is (= (vec (repeat 12 1)) (:eo s)))
    (is (cubie/solvable? s))))

(deftest orientation-convention-test
  (testing "only F/B quarter turns flip edges; only R/L/F/B quarter turns twist corners"
    (doseq [t moves/tokens
            :let [s (cubie/apply-move cubie/solved t)
                  flips (apply + (:eo s))
                  twists (apply + (:co s))]]
      (is (= (boolean (#{"F" "F'" "B" "B'"} t)) (pos? flips)) t)
      (is (= (boolean (and (#{\R \L \F \B} (first t)) (not= \2 (last (str t))))) (pos? twists)) t))))

(deftest solvable-test
  (is (not (cubie/solvable? (assoc cubie/solved :co [1 0 0 0 0 0 0 0]))))
  (is (not (cubie/solvable? (assoc cubie/solved :eo [1 0 0 0 0 0 0 0 0 0 0 0]))))
  (is (not (cubie/solvable? (assoc cubie/solved :cp [1 0 2 3 4 5 6 7]))))
  (is (not (cubie/solvable? (assoc cubie/solved :ep [0 1 2 3 4 5 6 7 8 9 11 10])))))

(deftest from-facelets-errors-test
  (is (thrown? clojure.lang.ExceptionInfo (cubie/from-facelets "UUU")))
  (is (thrown? clojure.lang.ExceptionInfo
               (cubie/from-facelets (apply str (repeat 54 \U))))))

(defspec model-agrees-with-facelets 200
  (prop/for-all [ts gen-tokens]
    (= (facelet/apply-moves facelet/solved ts)
       (cubie/->facelets (cubie/scramble ts)))))

(defspec facelets-roundtrip 100
  (prop/for-all [ts gen-tokens]
    (let [s (cubie/scramble ts)]
      (and (= s (cubie/from-facelets (cubie/->facelets s)))
           (cubie/solvable? s)))))

(defspec scramble-then-inverse-is-solved 100
  (prop/for-all [ts gen-tokens]
    (cubie/solved? (cubie/apply-moves (cubie/scramble ts) (moves/invert ts)))))

(defspec apply-moves-is-fold-of-apply-move 50
  (prop/for-all [ts gen-tokens]
    (= (cubie/scramble ts) (reduce cubie/apply-move cubie/solved ts))))
