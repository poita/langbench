(ns qrcode.matrix
  "The module grid: function patterns, format/version information and
  zigzag data placement.

  A grid is a flat row-major byte array (1 = dark, 0 = light) of `size * size`
  modules, plus a parallel boolean array marking function modules (which are
  never masked and never carry data). Module (x, y) is at index `y*size + x`."
  (:require [qrcode.tables :as tables]))

(set! *warn-on-reflection* true)

(defrecord Grid [^long size ^bytes modules ^booleans function])

(defn- set-module!
  "Sets module (x, y) to `dark?` and marks it as a function module."
  [^Grid g ^long x ^long y dark?]
  (let [i (+ (* y (.-size g)) x)]
    (aset ^bytes (.-modules g) i (byte (if dark? 1 0)))
    (aset ^booleans (.-function g) i true)))

(defn- draw-timing! [^Grid g]
  (dotimes [i (.-size g)]
    (let [dark? (even? i)]
      (set-module! g i 6 dark?)
      (set-module! g 6 i dark?))))

(defn- draw-finder!
  "Draws a finder pattern and its separator centred at (cx, cy), clipped to
  the symbol."
  [^Grid g ^long cx ^long cy]
  (let [n (.-size g)]
    (doseq [dy (range -4 5), dx (range -4 5)]
      (let [x (+ cx dx), y (+ cy dy)]
        (when (and (< -1 x n) (< -1 y n))
          (let [d (max (abs dx) (abs dy))]
            (set-module! g x y (not (or (== d 2) (== d 4))))))))))

(defn- draw-alignment!
  "Draws a 5x5 alignment pattern centred at (cx, cy)."
  [^Grid g ^long cx ^long cy]
  (doseq [dy (range -2 3), dx (range -2 3)]
    (set-module! g (+ cx dx) (+ cy dy) (not= 1 (max (abs dx) (abs dy))))))

(defn- bch-remainder
  "Remainder used by format (poly 0x537, 10 check bits) and version
  (poly 0x1F25, 12 check bits) information."
  ^long [^long data ^long degree ^long poly]
  (loop [i 0, rem data]
    (if (== i degree)
      rem
      (recur (inc i)
             (bit-xor (bit-shift-left rem 1)
                      (* (bit-shift-right rem (dec degree)) poly))))))

(defn format-bits
  "The 15 format information bits (including the 0x5412 XOR mask) for `ecl`
  and mask number `mask`."
  ^long [ecl ^long mask]
  (let [data (bit-or (bit-shift-left (long (tables/ecl-format-bits ecl)) 3) mask)
        rem (bch-remainder data 10 0x537)]
    (bit-xor (bit-or (bit-shift-left data 10) rem) 0x5412)))

(defn version-bits
  "The 18 version information bits for version `v` (>= 7)."
  ^long [^long v]
  (bit-or (bit-shift-left v 12) (bch-remainder v 12 0x1F25)))

(defn draw-format!
  "Writes both copies of the format information for `ecl` and `mask`."
  [^Grid g ecl ^long mask]
  (let [n (.-size g)
        bits (format-bits ecl mask)
        bit (fn [i] (bit-test bits i))]
    ;; First copy, around the top-left finder.
    (dotimes [i 6] (set-module! g 8 i (bit i)))
    (set-module! g 8 7 (bit 6))
    (set-module! g 8 8 (bit 7))
    (set-module! g 7 8 (bit 8))
    (doseq [i (range 9 15)] (set-module! g (- 14 i) 8 (bit i)))
    ;; Second copy, split between the other two finders.
    (dotimes [i 8] (set-module! g (- n 1 i) 8 (bit i)))
    (doseq [i (range 8 15)] (set-module! g 8 (+ (- n 15) i) (bit i)))
    ;; The always-dark module.
    (set-module! g 8 (- n 8) true)
    g))

(defn- draw-version! [^Grid g ^long v]
  (when (>= v 7)
    (let [n (.-size g)
          bits (version-bits v)]
      (dotimes [i 18]
        (let [dark? (bit-test bits i)
              a (+ (- n 11) (mod i 3))
              b (quot i 3)]
          (set-module! g a b dark?)
          (set-module! g b a dark?))))))

(defn function-patterns
  "Creates the grid for version `v` containing every function pattern.
  Format modules are reserved (light) until `draw-format!` is called."
  ^Grid [^long v]
  (let [n (tables/symbol-size v)
        g (->Grid n (byte-array (* n n)) (boolean-array (* n n)))
        pos (tables/alignment-positions v)
        lastp (peek pos)
        firstp (first pos)]
    (draw-timing! g)
    (draw-finder! g 3 3)
    (draw-finder! g (- n 4) 3)
    (draw-finder! g 3 (- n 4))
    (doseq [px pos, py pos
            :when (not (or (and (== px firstp) (== py firstp))
                           (and (== px lastp) (== py firstp))
                           (and (== px firstp) (== py lastp))))]
      (draw-alignment! g px py))
    (draw-format! g :l 0)
    (draw-version! g v)
    g))

(defn place-data!
  "Writes the codeword sequence `cw` (an int array) into the non-function
  modules of `g` following the zigzag order. Unused modules stay light."
  [^Grid g ^ints cw]
  (let [n (.-size g)
        modules ^bytes (.-modules g)
        function ^booleans (.-function g)
        nbits (* 8 (alength cw))]
    (loop [right (dec n), k 0]
      (when (>= right 1)
        (let [right (if (== right 6) 5 right)
              upward? (zero? (bit-and (inc right) 2))
              k (long (loop [vert 0, k k]
                  (if (== vert n)
                    k
                    (let [y (if upward? (- n 1 vert) vert)
                          k (long (loop [j 0, k k]
                              (if (== j 2)
                                k
                                (let [x (- right j)
                                      i (+ (* y n) x)]
                                  (if (or (aget function i) (>= k nbits))
                                    (recur (inc j) k)
                                    (do (when (bit-test (aget cw (bit-shift-right k 3))
                                                        (- 7 (bit-and k 7)))
                                          (aset modules i (byte 1)))
                                        (recur (inc j) (inc k))))))))]
                      (recur (inc vert) k)))))]
          (recur (- right 2) k))))
    g))

(defn copy-grid
  "A copy of `g` with its own module array (the function map is shared, as it
  is never modified after construction)."
  ^Grid [^Grid g]
  (->Grid (.-size g) (aclone ^bytes (.-modules g)) (.-function g)))

(defn dark?
  "True when module (x, y) of `g` is dark."
  [^Grid g ^long x ^long y]
  (== 1 (aget ^bytes (.-modules g) (+ (* y (.-size g)) x))))
