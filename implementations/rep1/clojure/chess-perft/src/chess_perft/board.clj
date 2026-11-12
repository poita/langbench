(ns chess-perft.board
  "Board representation: piece and square encodings, the immutable
  [[Position]] record, and FEN parsing / printing.

  Encodings (all plain longs/ints so that hot loops stay primitive):

  * square  - `0..63`, `rank * 8 + file`, so a1 = 0, h1 = 7, a8 = 56, h8 = 63;
  * colour  - [[white]] = 0, [[black]] = 1;
  * piece   - `type | colour << 3`; `0` is an empty square;
  * castling rights - a bit set of [[castle-wk]], [[castle-wq]],
    [[castle-bk]], [[castle-bq]];
  * en passant - the target square, or `-1` when there is none."
  (:require [clojure.string :as str]))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------- constants

(def ^:const white 0)
(def ^:const black 1)

(def ^:const pawn 1)
(def ^:const knight 2)
(def ^:const bishop 3)
(def ^:const rook 4)
(def ^:const queen 5)
(def ^:const king 6)

(def ^:const castle-wk 1)
(def ^:const castle-wq 2)
(def ^:const castle-bk 4)
(def ^:const castle-bq 8)

(def ^:const no-square -1)

(definline piece
  "The piece code of `type` (e.g. [[knight]]) owned by `colour`."
  [colour type]
  `(bit-or ~type (bit-shift-left ~colour 3)))

(definline piece-type
  "The type (`1..6`) of the non-empty piece code `p`."
  [p]
  `(bit-and ~p 7))

(definline piece-colour
  "The colour of the non-empty piece code `p`."
  [p]
  `(bit-shift-right ~p 3))

(definline square
  "The square index of `file` (0 = a) and `rank` (0 = rank 1)."
  [file rank]
  `(bit-or (bit-shift-left ~rank 3) ~file))

(definline file-of
  "The file (0 = a .. 7 = h) of square `sq`."
  [sq]
  `(bit-and ~sq 7))

(definline rank-of
  "The rank (0 = rank 1 .. 7 = rank 8) of square `sq`."
  [sq]
  `(bit-shift-right ~sq 3))

(defn square->str
  "The algebraic name of `sq`, e.g. `\"e4\"`."
  [^long sq]
  (str (char (+ 97 (file-of sq))) (char (+ 49 (rank-of sq)))))

(defn str->square
  "The square index named by `s` (e.g. `\"e4\"` => 28)."
  ^long [^String s]
  (let [f (- (int (.charAt s 0)) 97)
        r (- (int (.charAt s 1)) 49)]
    (when-not (and (<= 0 f 7) (<= 0 r 7))
      (throw (ex-info "Invalid square" {:square s})))
    (square f r)))

;; ----------------------------------------------------------------- position

(defrecord Position [^ints board ^long side ^long castling ^long ep])

(alter-meta! #'->Position assoc :doc
             "Positional constructor. `board` is an int-array of 64 piece
  codes, `side` the colour to move, `castling` the rights bit set and `ep`
  the en passant target square or -1. Positions are values: nothing in this
  library mutates the board array of a Position it has been given.")

(def ^:private ^String piece-chars "PNBRQK")

(defn- char->piece ^long [c]
  (let [i (.indexOf piece-chars (str (Character/toUpperCase (char c))))]
    (when (neg? i)
      (throw (ex-info "Invalid piece in FEN" {:char c})))
    (piece (if (Character/isUpperCase (char c)) white black) (inc i))))

(defn- piece->char [^long p]
  (let [c (.charAt piece-chars (dec (piece-type p)))]
    (if (== (piece-colour p) white) c (Character/toLowerCase c))))

(defn- parse-placement ^ints [^String placement]
  (let [board (int-array 64)
        ranks (str/split placement #"/" -1)]
    (when-not (== 8 (count ranks))
      (throw (ex-info "FEN placement needs 8 ranks" {:placement placement})))
    (doseq [[i ^String rank-str] (map-indexed vector ranks)]
      (let [rank (- 7 (long i))
            end  (reduce (fn [^long file c]
                           (when (> file 7)
                             (throw (ex-info "FEN rank too long" {:rank rank-str})))
                           (if (Character/isDigit (char c))
                             (+ file (- (long c) 48))
                             (do (aset-int board (square file rank) (char->piece c))
                                 (inc file))))
                         0 rank-str)]
        (when-not (== 8 (long end))
          (throw (ex-info "FEN rank must cover 8 files" {:rank rank-str})))))
    board))

(defn- parse-castling ^long [^String s]
  (if (= s "-")
    0
    (reduce (fn [^long acc c]
              (bit-or acc (case c
                            \K castle-wk \Q castle-wq
                            \k castle-bk \q castle-bq
                            (throw (ex-info "Invalid castling field" {:castling s})))))
            0 s)))

(defn- count-kings [^ints board colour]
  (let [k (piece colour king)]
    (count (filter #(== k (aget board %)) (range 64)))))

(defn parse-fen
  "Parses a FEN record into a [[Position]].

  The halfmove clock and fullmove number are optional and ignored. Throws
  `ex-info` on a malformed record or when a side lacks exactly one king."
  [^String fen]
  (let [[placement side castling ep] (str/split (str/trim fen) #"\s+")]
    (when-not (and placement side castling ep)
      (throw (ex-info "FEN needs at least four fields" {:fen fen})))
    (let [board (parse-placement placement)]
      (when-not (and (== 1 (count-kings board white))
                     (== 1 (count-kings board black)))
        (throw (ex-info "Each side needs exactly one king" {:fen fen})))
      (->Position board
                  (case side
                    "w" white
                    "b" black
                    (throw (ex-info "Invalid side to move" {:side side})))
                  (parse-castling castling)
                  (if (= ep "-") no-square (str->square ep))))))

(defn to-fen
  "Formats `pos` as a FEN record (with halfmove clock 0 and fullmove 1)."
  [^Position pos]
  (let [^ints board (.board pos)
        placement
        (str/join
         "/"
         (for [rank (range 7 -1 -1)]
           (let [sb (StringBuilder.)]
             (loop [file 0 empty 0]
               (if (< file 8)
                 (let [p (aget board (square file rank))]
                   (if (zero? p)
                     (recur (inc file) (inc empty))
                     (do (when (pos? empty) (.append sb empty))
                         (.append sb (piece->char p))
                         (recur (inc file) 0))))
                 (when (pos? empty) (.append sb empty))))
             (str sb))))
        c (.castling pos)
        castling (str (when (pos? (bit-and c castle-wk)) "K")
                      (when (pos? (bit-and c castle-wq)) "Q")
                      (when (pos? (bit-and c castle-bk)) "k")
                      (when (pos? (bit-and c castle-bq)) "q"))]
    (str placement " "
         (if (== (.side pos) white) "w" "b") " "
         (if (str/blank? castling) "-" castling) " "
         (if (neg? (.ep pos)) "-" (square->str (.ep pos)))
         " 0 1")))

(def start-fen
  "FEN of the standard starting position."
  "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")

(defn start-position
  "A fresh [[Position]] for the standard starting position."
  []
  (parse-fen start-fen))
