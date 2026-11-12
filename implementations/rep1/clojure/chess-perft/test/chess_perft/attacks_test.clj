(ns chess-perft.attacks-test
  (:require [chess-perft.attacks :as a]
            [chess-perft.board :as b]
            [clojure.test :refer [deftest is testing]]))

(defn- sq [s] (b/str->square s))
(defn- attacked? [fen square by & [ignore]]
  (a/attacked? (:board (b/parse-fen fen)) (sq square) by (if ignore (sq ignore) -1)))

(deftest tables
  (testing "target counts"
    (is (= 2 (alength ^ints (aget a/knight-targets (sq "a1")))))
    (is (= 8 (alength ^ints (aget a/knight-targets (sq "e4")))))
    (is (= 3 (alength ^ints (aget a/king-targets (sq "h8")))))
    (is (= 8 (alength ^ints (aget a/king-targets (sq "d4"))))))
  (testing "rays are ordered nearest first"
    (is (= [(sq "e5") (sq "e6") (sq "e7") (sq "e8")]
           (vec (aget a/rays (+ (* 0 64) (sq "e4"))))))
    (is (= [(sq "d3") (sq "c2") (sq "b1")]
           (vec (aget a/rays (+ (* 7 64) (sq "e4"))))))
    (is (empty? (aget a/rays (+ (* 0 64) (sq "e8"))))))
  (testing "pawn attacks depend on colour and edge"
    (is (= #{(sq "d5") (sq "f5")}
           (set (aget a/pawn-attacks (+ (* b/white 64) (sq "e4"))))))
    (is (= #{(sq "d3") (sq "f3")}
           (set (aget a/pawn-attacks (+ (* b/black 64) (sq "e4"))))))
    (is (= #{(sq "b5")}
           (set (aget a/pawn-attacks (+ (* b/white 64) (sq "a4"))))))))

(deftest attacked-by-each-piece
  (is (attacked? "4k3/8/8/8/8/8/8/R3K3 w - -" "a8" b/white))
  (is (not (attacked? "4k3/8/8/8/8/8/8/R3K3 w - -" "b8" b/white)))
  (is (attacked? "4k3/8/8/8/3N4/8/8/4K3 w - -" "e6" b/white))
  (is (attacked? "4k3/8/8/8/3B4/8/8/4K3 w - -" "g7" b/white))
  (is (attacked? "4k3/8/8/8/3Q4/8/8/4K3 w - -" "d8" b/white))
  (is (attacked? "4k3/8/8/8/3P4/8/8/4K3 w - -" "e5" b/white))
  (is (not (attacked? "4k3/8/8/8/3P4/8/8/4K3 w - -" "d5" b/white)))
  (is (attacked? "4k3/8/8/8/3p4/8/8/4K3 w - -" "c3" b/black))
  (is (attacked? "4k3/8/8/8/8/8/8/4K3 w - -" "d2" b/white)))

(deftest blockers-and-ignore
  (is (not (attacked? "4k3/8/8/8/8/P7/8/R3K3 w - -" "a8" b/white))
      "a pawn blocks the rook")
  (is (attacked? "4k3/8/8/8/8/P7/8/R3K3 w - -" "a8" b/white "a3")
      "unless the blocker is ignored")
  (testing "slider x-rays through the lifted king"
    (is (attacked? "4r2k/8/8/8/8/8/4K3/8 w - -" "e1" b/black "e2"))
    (is (not (attacked? "4r2k/8/8/8/8/8/4K3/8 w - -" "e1" b/black)))))
