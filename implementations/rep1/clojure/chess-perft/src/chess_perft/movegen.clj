(ns chess-perft.movegen
  "Legal move generation driven by check and pin information.

  For the side to move the generator first finds the king, the pieces that
  give check and the pieces pinned to the king ([[analyse!]]). That yields

  * a *check mask*: the squares a non-king move must land on to deal with a
    check (all squares when not in check, none in double check), and
  * a *pin mask* per pinned piece: the squares on the pin line.

  A knight, slider or pawn move is legal exactly when its destination lies in
  both masks, so those moves are produced without ever being played. Only
  king moves (tested with the king lifted off the board) and en passant
  captures (played, then the king is checked) need a separate legality test."
  (:require [chess-perft.attacks :as a]
            [chess-perft.board :as b]
            [chess-perft.move :as m])
  (:import [chess_perft.board Position]))

(set! *warn-on-reflection* true)

(defn- bit-set-at?
  "True when bit `sq` of `mask` is set."
  [^long mask ^long sq]
  (not (zero? (bit-and mask (bit-shift-left 1 sq)))))

(defn- king-square
  ^long [^ints board ^long side]
  (let [k (b/piece side b/king)]
    (loop [sq 0]
      (cond (== sq 64) (throw (ex-info "No king on the board" {:side side}))
            (== k (aget board sq)) sq
            :else (recur (inc sq))))))

;; ----------------------------------------------------- checks and pins

(defn- scan-ray!
  "Walks direction `d` from the king on `ksq`. If the first enemy slider that
  moves along `d` is met with no piece of ours in between, returns the bits of
  the squares from the king up to and including it (a check). If exactly one
  piece of ours is in between, records the same bits in `pins` for that piece
  and returns 0."
  ^long [^ints board ^longs pins ^long ksq ^long d]
  (let [side   (b/piece-colour (aget board ksq))
        enemy  (- 1 side)
        ^ints ray (aget a/rays (+ (* d 64) ksq))
        sliders (bit-or (bit-shift-left 1 (b/piece enemy b/queen))
                        (bit-shift-left 1 (b/piece enemy (if (< d 4) b/rook b/bishop))))
        n (alength ray)]
    (loop [i 0 own -1 line 0]
      (if (< i n)
        (let [s    (aget ray i)
              p    (aget board s)
              line (bit-or line (bit-shift-left 1 s))]
          (cond
            (zero? p) (recur (inc i) own line)
            (== (b/piece-colour p) side) (if (neg? own) (recur (inc i) s line) 0)
            (bit-set-at? sliders p) (if (neg? own)
                                      line
                                      (do (aset-long pins own line) 0))
            :else 0))
        0))))

(defn- add-checker
  "Combines the check mask so far (-1 = no check yet) with a new checker whose
  capture-or-block squares are `line`: a second checker leaves no square."
  ^long [^long mask ^long line]
  (if (== mask -1) line 0))

(defn- contact-checks
  "Folds into `mask` every square of `squares` holding exactly `piece`."
  ^long [^ints board ^ints squares ^long piece ^long mask]
  (let [n (alength squares)]
    (loop [i 0 mask mask]
      (if (< i n)
        (let [s (aget squares i)]
          (if (== piece (aget board s))
            (recur (inc i) (add-checker mask (bit-shift-left 1 s)))
            (recur (inc i) mask)))
        mask))))

(defn- analyse!
  "Computes the check mask for `side`'s king on `ksq` (-1 = not in check,
  0 = double check, otherwise the squares that capture or block the single
  checker) and fills `pins` (long-array 64, 0 = not pinned) with pin lines."
  ^long [^ints board ^longs pins ^long side ^long ksq]
  (let [enemy (- 1 side)
        mask  (loop [d 0 mask -1]
                (if (< d 8)
                  (let [line (scan-ray! board pins ksq d)]
                    (recur (inc d) (if (zero? line) mask (add-checker mask line))))
                  mask))
        mask  (contact-checks board (aget a/knight-targets ksq)
                              (b/piece enemy b/knight) mask)]
    (contact-checks board (aget a/pawn-attacks (+ (* side 64) ksq))
                    (b/piece enemy b/pawn) mask)))

;; ------------------------------------------------------------- generation

(defn- gen-knight! [^ints board ^ints ml ^long sq ^long mask]
  (let [side (b/piece-colour (aget board sq))
        ^ints dests (aget a/knight-targets sq)
        n (alength dests)]
    (loop [i 0]
      (when (< i n)
        (let [to (aget dests i) q (aget board to)]
          (when (and (bit-set-at? mask to)
                     (or (zero? q) (not= side (b/piece-colour q))))
            (m/movelist-add! ml (m/move sq to 0 m/special-none))))
        (recur (inc i))))))

(defn- gen-sliding!
  "Bishop, rook and queen moves of the piece on `sq`."
  [^ints board ^ints ml ^long sq ^long mask]
  (let [p    (aget board sq)
        side (b/piece-colour p)
        t    (b/piece-type p)
        d0   (if (== t b/bishop) 4 0)
        d1   (if (== t b/rook) 4 8)]
    (loop [d d0]
      (when (< d d1)
        (let [^ints ray (aget a/rays (+ (* d 64) sq))
              n (alength ray)]
          (loop [i 0]
            (when (< i n)
              (let [to (aget ray i) q (aget board to)]
                (if (zero? q)
                  (do (when (bit-set-at? mask to)
                        (m/movelist-add! ml (m/move sq to 0 m/special-none)))
                      (recur (inc i)))
                  (when (and (not= side (b/piece-colour q)) (bit-set-at? mask to))
                    (m/movelist-add! ml (m/move sq to 0 m/special-none))))))))
        (recur (inc d))))))

(defn- add-pawn-move!
  "Adds a pawn move, expanded into the four promotions on the last rank."
  [^ints ml ^long from ^long to ^long last-rank]
  (if (== (b/rank-of to) last-rank)
    (do (m/movelist-add! ml (m/move from to b/queen m/special-none))
        (m/movelist-add! ml (m/move from to b/rook m/special-none))
        (m/movelist-add! ml (m/move from to b/bishop m/special-none))
        (m/movelist-add! ml (m/move from to b/knight m/special-none)))
    (m/movelist-add! ml (m/move from to 0 m/special-none))))

(defn- gen-pawn!
  "Pushes and ordinary captures of the pawn on `sq` (en passant is separate)."
  [^ints board ^ints ml ^long sq ^long mask]
  (let [side (b/piece-colour (aget board sq))
        white? (== side b/white)
        fwd (if white? 8 -8)
        start-rank (if white? 1 6)
        last-rank  (if white? 7 0)
        one (+ sq fwd)]
    (when (zero? (aget board one))
      (when (bit-set-at? mask one)
        (add-pawn-move! ml sq one last-rank))
      (let [two (+ one fwd)]
        (when (and (== (b/rank-of sq) start-rank)
                   (zero? (aget board two))
                   (bit-set-at? mask two))
          (m/movelist-add! ml (m/move sq two 0 m/special-double-push)))))
    (let [^ints caps (aget a/pawn-attacks (+ (* side 64) sq))
          n (alength caps)]
      (loop [i 0]
        (when (< i n)
          (let [to (aget caps i) q (aget board to)]
            (when (and (not (zero? q))
                       (not= side (b/piece-colour q))
                       (bit-set-at? mask to))
              (add-pawn-move! ml sq to last-rank)))
          (recur (inc i)))))))

(defn- gen-en-passant!
  "En passant captures. Each candidate is played and kept only if it leaves
  the king safe (this covers the rank-pin where two pawns vanish at once)."
  [^Position pos ^ints ml ^long ksq]
  (let [ep (.ep pos)]
    (when (>= ep 0)
      (let [board ^ints (.board pos)
            side (.side pos)
            enemy (- 1 side)
            victim (if (== side b/white) (- ep 8) (+ ep 8))
            ^ints from-sqs (aget a/pawn-attacks (+ (* enemy 64) ep))
            own-pawn (b/piece side b/pawn)]
        (when (== (aget board victim) (b/piece enemy b/pawn))
          (dotimes [i (alength from-sqs)]
            (let [from (aget from-sqs i)]
              (when (== own-pawn (aget board from))
                (let [mv (m/move from ep 0 m/special-en-passant)
                      after ^Position (m/make-move pos mv)]
                  (when-not (a/attacked? (.board after) ksq enemy -1)
                    (m/movelist-add! ml mv)))))))))))

(defn- gen-castling!
  "Castling moves for the king of `side` standing on `ksq`; only called when
  the king is not in check."
  [^ints board ^ints ml ^long castling ^long ksq]
  (let [side  (b/piece-colour (aget board ksq))
        base  (if (== side b/white) 0 56)
        enemy (- 1 side)
        rook  (b/piece side b/rook)
        safe? (fn [^long sq] (not (a/attacked? board sq enemy ksq)))
        empty? (fn [^long sq] (zero? (aget board sq)))]
    (when (== ksq (+ base 4))
      ;; kingside: f, g empty and unattacked
      (when (and (not (zero? (bit-and castling (if (== side b/white) b/castle-wk b/castle-bk))))
                 (== rook (aget board (+ base 7)))
                 (empty? (+ base 5)) (empty? (+ base 6))
                 (safe? (+ base 5)) (safe? (+ base 6)))
        (m/movelist-add! ml (m/move ksq (+ base 6) 0 m/special-castle)))
      ;; queenside: b, c, d empty; c, d unattacked
      (when (and (not (zero? (bit-and castling (if (== side b/white) b/castle-wq b/castle-bq))))
                 (== rook (aget board base))
                 (empty? (+ base 1)) (empty? (+ base 2)) (empty? (+ base 3))
                 (safe? (+ base 3)) (safe? (+ base 2)))
        (m/movelist-add! ml (m/move ksq (+ base 2) 0 m/special-castle))))))

(defn- gen-king!
  [^ints board ^ints ml ^long side ^long ksq]
  (let [^ints dests (aget a/king-targets ksq)
        enemy (- 1 side)
        n (alength dests)]
    (loop [i 0]
      (when (< i n)
        (let [to (aget dests i) q (aget board to)]
          (when (and (or (zero? q) (not= side (b/piece-colour q)))
                     (not (a/attacked? board to enemy ksq)))
            (m/movelist-add! ml (m/move ksq to 0 m/special-none))))
        (recur (inc i))))))

(defn generate!
  "Writes every legal move of `pos` into movelist `ml` (see
  [[chess-perft.move/new-movelist]]), replacing its contents."
  [^Position pos ^ints ml]
  (aset-int ml 0 0)
  (let [board ^ints (.board pos)
        side  (.side pos)
        ksq   (king-square board side)
        pins  (long-array 64)
        cmask (analyse! board pins side ksq)]
    (gen-king! board ml side ksq)
    (when (== cmask -1)
      (gen-castling! board ml (.castling pos) ksq))
    (when-not (zero? cmask)
      (loop [sq 0]
        (when (< sq 64)
          (let [p (aget board sq)]
            (when (and (not (zero? p)) (== side (b/piece-colour p)))
              (let [t (b/piece-type p)
                    pin (aget pins sq)
                    mask (if (zero? pin) cmask (bit-and pin cmask))]
                (cond
                  (== t b/pawn)   (gen-pawn! board ml sq mask)
                  (== t b/knight) (gen-knight! board ml sq mask)
                  (== t b/king)   nil
                  :else           (gen-sliding! board ml sq mask)))))
          (recur (inc sq))))
      (gen-en-passant! pos ml ksq))
    nil))

(defn count-legal-moves
  "The number of legal moves in `pos`."
  ^long [^Position pos]
  (let [ml (m/new-movelist)]
    (generate! pos ml)
    (aget ^ints ml 0)))

(defn legal-moves
  "A vector of all legal moves of `pos`, in generation order."
  [^Position pos]
  (let [ml (m/new-movelist)]
    (generate! pos ml)
    (m/movelist->vec ml)))
