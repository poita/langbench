(ns chess-perft.core
  "Public API of the chess-perft library: a legal chess move generator with
  perft and divide.

      (require '[chess-perft.core :as chess])

      (def pos (chess/parse-fen \"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1\"))
      (chess/perft pos 3)                    ;=> 8902
      (map chess/move->uci (chess/legal-moves pos))
      (chess/divide pos 2)                   ;=> [[\"a2a3\" 20] [\"a2a4\" 20] ...]
      (chess/to-fen (chess/play pos \"e2e4\"))

  A *position* is an immutable [[chess-perft.board/Position]]. A *move* is a
  long (see [[chess-perft.move]] for the encoding); use [[move->uci]] to
  print one and [[play]] to apply a UCI string."
  (:require [chess-perft.board :as board]
            [chess-perft.move :as move]
            [chess-perft.movegen :as movegen]
            [chess-perft.perft :as perft]))

(defn parse-fen
  "Parses a FEN record into a position. The clocks are optional and ignored.
  Throws `ex-info` for malformed input."
  [fen]
  (board/parse-fen fen))

(defn to-fen
  "Formats a position as FEN (halfmove clock 0, fullmove number 1)."
  [pos]
  (board/to-fen pos))

(defn start-position
  "The standard starting position."
  []
  (board/start-position))

(defn legal-moves
  "A vector of all legal moves in `pos` (as encoded longs)."
  [pos]
  (movegen/legal-moves pos))

(defn count-legal-moves
  "The number of legal moves in `pos`, without materialising them."
  [pos]
  (movegen/count-legal-moves pos))

(defn move->uci
  "UCI notation of a move, e.g. `\"e2e4\"`, `\"e1g1\"`, `\"a7a8q\"`."
  [mv]
  (move/move->uci mv))

(defn make-move
  "The position after playing the legal move `mv` in `pos`."
  [pos mv]
  (move/make-move pos mv))

(defn play
  "The position after playing the move written in UCI notation (e.g.
  `\"e2e4\"`). Throws `ex-info` if `uci` is not a legal move in `pos`."
  [pos uci]
  (if-let [mv (first (filter #(= uci (move/move->uci %)) (movegen/legal-moves pos)))]
    (move/make-move pos mv)
    (throw (ex-info "Illegal move" {:move uci :fen (board/to-fen pos)}))))

(defn perft
  "Number of leaf nodes of the legal-move tree of `depth` plies below `pos`
  (1 for depth 0). Walks the whole tree, counting the last ply in bulk."
  [pos depth]
  (perft/perft pos depth))

(defn divide
  "Per-root-move perft: a vector of `[uci count]` pairs sorted by the UCI
  string, where `count` is `(perft (play pos uci) (dec depth))`. `depth` >= 1."
  [pos depth]
  (perft/divide pos depth))
