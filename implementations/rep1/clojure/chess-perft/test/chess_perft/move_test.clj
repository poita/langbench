(ns chess-perft.move-test
  (:require [chess-perft.board :as b]
            [chess-perft.move :as m]
            [clojure.test :refer [deftest is testing]]))

(defn- sq [s] (b/str->square s))
(defn- mv [from to & [promo special]]
  (m/move (sq from) (sq to) (or promo 0) (or special m/special-none)))

(deftest encoding
  (let [x (m/move 52 60 b/queen m/special-none)]
    (is (= 52 (m/from-sq x)))
    (is (= 60 (m/to-sq x)))
    (is (= b/queen (m/promotion x)))
    (is (= m/special-none (m/special x))))
  (is (= "e2e4" (m/move->uci (mv "e2" "e4" 0 m/special-double-push))))
  (is (= "a7a8n" (m/move->uci (mv "a7" "a8" b/knight)))))

(deftest make-move-basics
  (let [pos (m/make-move (b/start-position) (mv "e2" "e4" 0 m/special-double-push))]
    (is (= "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1" (b/to-fen pos)))
    (is (= b/black (:side pos)))
    (testing "the source position is untouched"
      (is (= b/start-fen (b/to-fen (b/start-position)))))))

(deftest castling-moves-the-rook-and-drops-rights
  (let [pos (b/parse-fen "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")]
    (is (= "r3k2r/8/8/8/8/8/8/R4RK1 b kq - 0 1"
           (b/to-fen (m/make-move pos (mv "e1" "g1" 0 m/special-castle)))))
    (is (= "2kr3r/8/8/8/8/8/8/R3K2R w KQ - 0 1"
           (b/to-fen (m/make-move (assoc pos :side b/black)
                                  (mv "e8" "c8" 0 m/special-castle)))))))

(deftest rook-moves-and-captures-drop-rights
  (let [pos (b/parse-fen "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")]
    (is (= (bit-or b/castle-wq b/castle-bk b/castle-bq)
           (:castling (m/make-move pos (mv "h1" "h2"))))
        "moving the h1 rook")
    (is (= (bit-or b/castle-wq b/castle-bq)
           (:castling (m/make-move pos (mv "h1" "h8"))))
        "moving the h1 rook onto the h8 rook removes both rights")
    (is (= (bit-or b/castle-bk b/castle-bq)
           (:castling (m/make-move pos (mv "e1" "e2"))))
        "moving the king")))

(deftest en-passant-and-promotion
  (is (= "4k3/8/3P4/8/8/8/8/4K3 b - - 0 1"
         (b/to-fen (m/make-move (b/parse-fen "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1")
                                (mv "e5" "d6" 0 m/special-en-passant)))))
  (is (= "Q3k3/8/8/8/8/8/8/4K3 b - - 0 1"
         (b/to-fen (m/make-move (b/parse-fen "4k3/P7/8/8/8/8/8/4K3 w - - 0 1")
                                (mv "a7" "a8" b/queen))))))
