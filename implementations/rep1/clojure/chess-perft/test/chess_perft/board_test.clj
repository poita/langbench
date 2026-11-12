(ns chess-perft.board-test
  (:require [chess-perft.board :as b]
            [clojure.test :refer [deftest is testing]]))

(deftest square-names
  (is (= "a1" (b/square->str 0)))
  (is (= "h8" (b/square->str 63)))
  (is (= "e4" (b/square->str 28)))
  (is (= 28 (b/str->square "e4")))
  (is (thrown? clojure.lang.ExceptionInfo (b/str->square "i9"))))

(deftest parse-start-position
  (let [pos (b/start-position)
        board ^ints (:board pos)]
    (is (= b/white (:side pos)))
    (is (= 15 (:castling pos)))
    (is (= b/no-square (:ep pos)))
    (is (= (b/piece b/white b/rook) (aget board 0)))
    (is (= (b/piece b/white b/king) (aget board 4)))
    (is (= (b/piece b/black b/queen) (aget board 59)))
    (is (= 32 (count (filter pos? (seq board)))))))

(deftest parse-fields
  (let [pos (b/parse-fen "4k3/8/8/3pP3/8/8/8/R3K3 b Q d6 12 34")]
    (is (= b/black (:side pos)))
    (is (= b/castle-wq (:castling pos)))
    (is (= (b/str->square "d6") (:ep pos))))
  (testing "clock fields are optional"
    (is (= b/white (:side (b/parse-fen "4k3/8/8/8/8/8/8/4K3 w - -"))))))

(deftest fen-round-trip
  (doseq [fen ["rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
               "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"
               "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1"
               "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 b - - 0 1"]]
    (is (= fen (b/to-fen (b/parse-fen fen))))))

(deftest malformed-fen
  (doseq [bad ["" "8/8/8/8/8/8/8/8 w - -"
               "4k3/8/8/8/8/8/8/4K3 x - -"
               "4k3/8/8/8/8/8/8/4K w - -"
               "4k3/8/8/8/8/8/4K3 w - -"
               "4k3/8/8/8/8/8/8/4Z3 w - -"
               "4k3/8/8/8/8/8/8/4K3 w X -"
               "4k3/8/8/8/8/8/8/4K2K w - -"]]
    (is (thrown? clojure.lang.ExceptionInfo (b/parse-fen bad)) bad)))
