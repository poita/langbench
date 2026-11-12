(ns chess-perft.movegen-test
  (:require [chess-perft.board :as b]
            [chess-perft.move :as m]
            [chess-perft.movegen :as mg]
            [clojure.test :refer [deftest is testing]]))

(defn- ucis [fen]
  (set (map m/move->uci (mg/legal-moves (b/parse-fen fen)))))

(deftest start-position-moves
  (is (= 20 (mg/count-legal-moves (b/start-position))))
  (is (= 20 (count (mg/legal-moves (b/start-position)))))
  (is (contains? (ucis b/start-fen) "g1f3"))
  (is (contains? (ucis b/start-fen) "e2e4")))

(deftest promotions
  (is (= #{"a6a5" "a6b5" "a7a8q" "a7a8r" "a7a8b" "a7a8n"}
         (ucis "8/P1k5/K7/8/8/8/8/8 w - - 0 1")))
  (testing "capturing promotions"
    (is (= #{"b7a8q" "b7a8r" "b7a8b" "b7a8n"}
           (set (filter #(.startsWith ^String % "b7a8")
                        (ucis "r3k3/1P6/8/8/8/8/8/4K3 w - - 0 1")))))))

(deftest castling
  (let [moves (ucis "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")]
    (is (contains? moves "e1g1"))
    (is (contains? moves "e1c1")))
  (testing "no castling out of, through or into check"
    (is (not (contains? (ucis "r3k2r/8/8/8/4r3/8/8/R3K2R w KQkq - 0 1") "e1g1")))
    (is (not (contains? (ucis "r3k2r/8/8/8/5r2/8/8/R3K2R w KQkq - 0 1") "e1g1")))
    (is (not (contains? (ucis "r3k2r/8/8/8/6r1/8/8/R3K2R w KQkq - 0 1") "e1g1")))
    (is (not (contains? (ucis "r3k2r/8/8/8/3r4/8/8/R3K2R w KQkq - 0 1") "e1c1")))
    (is (not (contains? (ucis "r3k2r/8/8/8/2r5/8/8/R3K2R w KQkq - 0 1") "e1c1"))))
  (testing "an attacked b1 or rook does not prevent queenside castling"
    (is (contains? (ucis "r3k2r/8/8/8/1r6/8/8/R3K2R w KQkq - 0 1") "e1c1")))
  (testing "blocked and missing rights"
    (is (not (contains? (ucis "r3k2r/8/8/8/8/8/8/RN2K2R w KQkq - 0 1") "e1c1")))
    (is (not (contains? (ucis "r3k2r/8/8/8/8/8/8/R3K2R w Qkq - 0 1") "e1g1")))
    (is (contains? (ucis "r3k2r/8/8/8/8/8/8/R3K2R b kq - 0 1") "e8c8"))))

(deftest en-passant
  (is (contains? (ucis "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1") "e5d6"))
  (testing "an ep square nobody can use yields nothing"
    (is (not-any? #(= "e5d6" %) (ucis "4k3/8/8/3p4/8/8/8/4K3 w - d6 0 1"))))
  (testing "capture that exposes the king along the rank is illegal"
    (is (not (contains? (ucis "8/8/8/K2pP2r/8/8/8/7k w - d6 0 1") "e5d6"))))
  (testing "capture that removes the checking pawn is legal"
    (is (contains? (ucis "8/8/8/2k5/3Pp3/8/8/4K3 b - d3 0 1") "e4d3"))))

(deftest checks
  (testing "double check allows only king moves"
    (is (seq (ucis "4k3/8/8/8/1b6/5n2/8/R3KQ2 w - - 0 1")))
    (is (every? #(.startsWith ^String % "e1")
                (ucis "4k3/8/8/8/1b6/5n2/8/R3KQ2 w - - 0 1"))))
  (testing "blocking a single check, or moving the king"
    (is (= #{"d2e3" "e1d1" "e1f1" "e1f2"}
           (ucis "4r2k/8/8/8/8/8/3B4/R3K3 w - - 0 1"))))
  (testing "capturing the checker"
    (is (= #{"d1e2" "e1e2" "e1f1"}
           (ucis "7k/8/8/8/8/8/4r3/3BK3 w - - 0 1"))))
  (testing "king cannot retreat along the checking line"
    (is (not (contains? (ucis "4r2k/8/8/8/8/8/4K3/8 w - - 0 1") "e2e1")))))

(deftest pins
  (testing "a pinned rook may only slide along the pin"
    (is (= #{"e2e3" "e2e4" "e2e5" "e2e6" "e2e7" "e2e8"}
           (set (filter #(.startsWith ^String % "e2")
                        (remove #(.startsWith ^String % "e1")
                                (ucis "4r2k/8/8/8/8/8/4R3/4K3 w - - 0 1")))))))
  (testing "a pinned knight cannot move"
    (is (not-any? #(.startsWith ^String % "e2")
                  (ucis "4r2k/8/8/8/8/8/4N3/4K3 w - - 0 1"))))
  (testing "a diagonally pinned pawn may capture its pinner only"
    (is (= #{"d2c3"}
           (set (filter #(.startsWith ^String % "d2")
                        (ucis "7k/8/8/8/8/2b5/3P4/4K3 w - - 0 1")))))))

(deftest no-legal-moves
  (is (empty? (ucis "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1")) "stalemate")
  (is (empty? (ucis "R6k/6pp/8/8/8/8/8/4K3 b - - 0 1")) "checkmate"))
