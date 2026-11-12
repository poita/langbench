(ns chess-perft.attacks
  "Precomputed geometry tables (rays, knight/king/pawn targets) and the
  square-attacked test.

  Directions are numbered `0..7`: `0..3` are the orthogonals (north, south,
  east, west) and `4..7` the diagonals (NE, NW, SE, SW), so a rook slides
  along directions `0..3`, a bishop along `4..7` and a queen along all
  eight."
  (:require [chess-perft.board :as b]))

(set! *warn-on-reflection* true)

(def ^:private direction-deltas
  "[file-delta rank-delta] for directions 0..7."
  [[0 1] [0 -1] [1 0] [-1 0] [1 1] [-1 1] [1 -1] [-1 -1]])

(defn- on-board? [f r] (and (<= 0 f 7) (<= 0 r 7)))

(defn- targets
  "Squares reached from `sq` by each of `deltas` that stay on the board."
  ^ints [sq deltas]
  (let [f (b/file-of sq) r (b/rank-of sq)]
    (int-array (for [[df dr] deltas
                     :when (on-board? (+ f df) (+ r dr))]
                 (b/square (+ f df) (+ r dr))))))

(defn- ray [sq [df dr]]
  (let [f (b/file-of sq) r (b/rank-of sq)]
    (int-array (loop [k 1 acc []]
                 (if (on-board? (+ f (* k df)) (+ r (* k dr)))
                   (recur (inc k) (conj acc (b/square (+ f (* k df)) (+ r (* k dr)))))
                   acc)))))

(def ^"[Ljava.lang.Object;" rays
  "`(aget rays (+ (* dir 64) sq))` is an int-array of the squares met when
  walking from `sq` in direction `dir`, nearest first, edge of board excluded
  from the start square."
  (object-array (for [d (range 8) sq (range 64)] (ray sq (direction-deltas d)))))

(def ^"[Ljava.lang.Object;" knight-targets
  "`(aget knight-targets sq)` is an int-array of the squares a knight on `sq`
  attacks."
  (object-array
   (for [sq (range 64)]
     (targets sq [[1 2] [2 1] [2 -1] [1 -2] [-1 -2] [-2 -1] [-2 1] [-1 2]]))))

(def ^"[Ljava.lang.Object;" king-targets
  "`(aget king-targets sq)` is an int-array of the squares a king on `sq`
  attacks."
  (object-array
   (for [sq (range 64)] (targets sq direction-deltas))))

(def ^"[Ljava.lang.Object;" pawn-attacks
  "`(aget pawn-attacks (+ (* colour 64) sq))` is an int-array of the squares a
  pawn of `colour` standing on `sq` attacks. By symmetry it is also the set of
  squares from which an enemy pawn would attack `sq`."
  (object-array
   (for [colour [b/white b/black]
         sq (range 64)]
     (let [dr (if (== colour b/white) 1 -1)]
       (targets sq [[-1 dr] [1 dr]])))))

(defn- ray-attacked?
  "Walks `ray`; true when the first occupied square (squares equal to
  `ignore` count as empty) holds a piece whose bit is set in `mask`."
  [^ints board ^ints ray ^long ignore ^long mask]
  (let [n (alength ray)]
    (loop [i 0]
      (if (< i n)
        (let [s (aget ray i)]
          (if (== s ignore)
            (recur (inc i))
            (let [p (aget board s)]
              (if (zero? p)
                (recur (inc i))
                (not (zero? (bit-and mask (bit-shift-left 1 p))))))))
        false))))

(defn- any-piece?
  "True when any square in `squares` holds exactly piece code `p`."
  [^ints board ^ints squares ^long p]
  (let [n (alength squares)]
    (loop [i 0]
      (and (< i n)
           (or (== p (aget board (aget squares i)))
               (recur (inc i)))))))

(defn attacked?
  "True when square `sq` is attacked by a piece of colour `by` on `board`.

  Square `ignore` (use -1 for none) is treated as empty. Move generation uses
  this to test king destinations with the king lifted off its origin square,
  so that a slider's line *behind* the king is correctly seen."
  [^ints board ^long sq ^long by ^long ignore]
  (let [enemy-pawn (b/piece by b/pawn)
        straight   (bit-or (bit-shift-left 1 (b/piece by b/queen))
                           (bit-shift-left 1 (b/piece by b/rook)))
        diagonal   (bit-or (bit-shift-left 1 (b/piece by b/queen))
                           (bit-shift-left 1 (b/piece by b/bishop)))]
    (boolean
     (or (any-piece? board (aget knight-targets sq) (b/piece by b/knight))
         (any-piece? board (aget king-targets sq) (b/piece by b/king))
         (any-piece? board (aget pawn-attacks (+ (* (- 1 by) 64) sq)) enemy-pawn)
         (loop [d 0]
           (and (< d 8)
                (or (ray-attacked? board (aget rays (+ (* d 64) sq)) ignore
                                   (if (< d 4) straight diagonal))
                    (recur (inc d)))))))))
