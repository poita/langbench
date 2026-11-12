(ns chess-perft.move
  "Move encoding, UCI text conversion and making a move on a position.

  A move is a long: `from | to << 6 | promotion << 12 | special << 15`, where
  `promotion` is the promoted piece type ([[chess-perft.board/knight]] ..
  [[chess-perft.board/queen]]) or 0, and `special` is one of
  [[special-none]], [[special-double-push]], [[special-en-passant]] or
  [[special-castle]]."
  (:require [chess-perft.board :as b])
  (:import [chess_perft.board Position]))

(set! *warn-on-reflection* true)

(def ^:const special-none 0)
(def ^:const special-double-push 1)
(def ^:const special-en-passant 2)
(def ^:const special-castle 3)

(definline move
  "Encodes a move. Pass 0 for `promotion` and [[special-none]] for a plain move."
  [from to promotion special]
  `(bit-or ~from
           (bit-shift-left ~to 6)
           (bit-shift-left ~promotion 12)
           (bit-shift-left ~special 15)))

(definline from-sq "Origin square of move `m`." [m] `(bit-and ~m 63))
(definline to-sq "Destination square of move `m`." [m] `(bit-and (bit-shift-right ~m 6) 63))
(definline promotion "Promotion piece type of `m`, or 0." [m] `(bit-and (bit-shift-right ~m 12) 7))
(definline special "Special-move kind of `m` (see the `special-*` constants)." [m]
  `(bit-and (bit-shift-right ~m 15) 3))

(defn move->uci
  "UCI long algebraic notation of `m`, e.g. `\"e2e4\"` or `\"a7a8q\"`."
  [^long m]
  (str (b/square->str (from-sq m))
       (b/square->str (to-sq m))
       (when (pos? (promotion m))
         (.charAt "..nbrq" (promotion m)))))

;; Movelists are int-arrays of 256 slots: slot 0 holds the number of moves,
;; slots 1..n the moves. 256 exceeds the maximum number of legal moves (218).

(defn new-movelist
  "A fresh, empty movelist."
  []
  (int-array 256))

(defn movelist-add!
  "Appends move `m` to movelist `ml`."
  [^ints ml ^long m]
  (let [n (inc (aget ml 0))]
    (aset-int ml n m)
    (aset-int ml 0 n)))

(defn movelist->vec
  "The moves held in `ml` as a vector of longs."
  [^ints ml]
  (let [n (aget ml 0)]
    (persistent!
     (loop [i 1 acc (transient [])]
       (if (<= i n) (recur (inc i) (conj! acc (long (aget ml i)))) acc)))))

;; Bits of the castling rights that survive a move touching each square.
(def ^:private ^"[I" castling-keep
  (let [a (int-array 64 15)]
    (aset-int a 4 (bit-and 15 (bit-not (bit-or b/castle-wk b/castle-wq))))
    (aset-int a 0 (bit-and 15 (bit-not b/castle-wq)))
    (aset-int a 7 (bit-and 15 (bit-not b/castle-wk)))
    (aset-int a 60 (bit-and 15 (bit-not (bit-or b/castle-bk b/castle-bq))))
    (aset-int a 56 (bit-and 15 (bit-not b/castle-bq)))
    (aset-int a 63 (bit-and 15 (bit-not b/castle-bk)))
    a))

(defn make-move
  "Returns the position reached by playing the (legal) move `m` in `pos`.
  `pos` is not modified."
  [^Position pos ^long m]
  (let [board   (aclone ^ints (.board pos))
        side    (.side pos)
        from    (from-sq m)
        to      (to-sq m)
        promo   (promotion m)
        special (special m)
        piece   (aget board from)]
    (aset-int board from 0)
    (aset-int board to (if (zero? promo) piece (b/piece side promo)))
    (when (== special special-en-passant)
      (aset-int board (if (== side b/white) (- to 8) (+ to 8)) 0))
    (when (== special special-castle)
      (let [rook (b/piece side b/rook)]
        (case (int to)
          6  (do (aset-int board 7 0)  (aset-int board 5 rook))
          2  (do (aset-int board 0 0)  (aset-int board 3 rook))
          62 (do (aset-int board 63 0) (aset-int board 61 rook))
          58 (do (aset-int board 56 0) (aset-int board 59 rook)))))
    (b/->Position board
                  (- 1 side)
                  (bit-and (.castling pos)
                           (aget castling-keep from)
                           (aget castling-keep to))
                  (if (== special special-double-push)
                    (quot (+ from to) 2)
                    b/no-square))))
