(ns rubiks.facelet
  "Reference facelet-level model of the cube, transcribed from the
  specification's net and 4-cycle move definitions.

  A cube is a 54-character string: nine stickers for each of the faces
  U R F D L B (in that order), each face numbered 1-9 in reading order, every
  character being the face letter whose centre the sticker matches. The solved
  cube is [[solved]].

  This model is deliberately simple and slow. The solver works on the cubie
  model in [[rubiks.cubie]]; this one is the ground truth that model is derived
  from and tested against."
  (:require [clojure.string :as str]
            [rubiks.moves :as moves]))

(def solved
  "The solved cube."
  (apply str (mapcat #(repeat 9 %) moves/faces)))

(defn index
  "Index (0-53) of a facelet name such as \"U1\" or \"B9\"."
  ^long [name]
  (+ (* 9 (long (.indexOf ^java.util.List moves/faces (first name))))
     (- (long (Character/digit (char (second name)) 10)) 1)))

(def ^:private cycle-text
  {\U "(U1 U3 U9 U7)(U2 U6 U8 U4)(F1 L1 B1 R1)(F2 L2 B2 R2)(F3 L3 B3 R3)"
   \D "(D1 D3 D9 D7)(D2 D6 D8 D4)(F7 R7 B7 L7)(F8 R8 B8 L8)(F9 R9 B9 L9)"
   \R "(R1 R3 R9 R7)(R2 R6 R8 R4)(F3 U3 B7 D3)(F6 U6 B4 D6)(F9 U9 B1 D9)"
   \L "(L1 L3 L9 L7)(L2 L6 L8 L4)(F1 D1 B9 U1)(F4 D4 B6 U4)(F7 D7 B3 U7)"
   \F "(F1 F3 F9 F7)(F2 F6 F8 F4)(U7 R1 D3 L9)(U8 R4 D2 L6)(U9 R7 D1 L3)"
   \B "(B1 B3 B9 B7)(B2 B6 B8 B4)(U3 L1 D7 R9)(U2 L4 D8 R6)(U1 L7 D9 R3)"})

(defn- cycles->source
  "Source table of a move given as cycles: after the move, position `i` holds
  the sticker that was at `(source i)`. A cycle `(a b c d)` sends the sticker
  at a to b, b to c, c to d and d to a."
  [text]
  (reduce (fn [src cycle]
            (let [idx (mapv index (str/split (str/trim cycle) #"\s+"))]
              (reduce (fn [src [a b]] (assoc src b a))
                      src
                      (map vector idx (conj (subvec idx 1) (first idx))))))
          (vec (range 54))
          (map second (re-seq #"\(([^)]*)\)" text))))

(defn- then
  "Source table of \"apply p, then q\"."
  [p q]
  (mapv #(nth p (nth q %)) (range 54)))

(def sources
  "Source tables of all eighteen moves, indexed by move id: after move `m`,
  facelet `i` shows the sticker that was at `(nth (sources m) i)`."
  (vec (mapcat (fn [f]
                 (let [q (cycles->source (cycle-text f))
                       h (then q q)]
                   [q h (then h q)]))
               moves/faces)))

(defn apply-move
  "Apply one move token to a facelet string."
  [^String state token]
  (let [src (sources (moves/token->id token))]
    (apply str (map #(.charAt state (long %)) src))))

(defn apply-moves
  "Apply a sequence of move tokens to a facelet string."
  [state tokens]
  (reduce apply-move state tokens))

(defn solved?
  "True when every face of the facelet string shows a single colour that
  matches its centre."
  [^String state]
  (= state solved))
