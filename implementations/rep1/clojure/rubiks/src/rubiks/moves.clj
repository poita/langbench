(ns rubiks.moves
  "The vocabulary of cube moves.

  A *token* is one of the eighteen strings `U D L R F B` (clockwise quarter
  turn), the same followed by `'` (counter-clockwise) or `2` (half turn).
  A *move id* is the token's index in [[tokens]]: `3 * face + k`, where faces
  are numbered in the order U R F D L B and `k` is 0 for a quarter turn,
  1 for a half turn and 2 for an inverse quarter turn.

  This namespace has no dependencies on the rest of the library."
  (:require [clojure.string :as str]))

(def faces
  "Face letters in index order. This order is used for every face-indexed
  structure in the library (facelet strings, move ids, centres)."
  [\U \R \F \D \L \B])

(def tokens
  "All eighteen move tokens, indexed by move id."
  (vec (for [f faces, suffix ["" "2" "'"]] (str f suffix))))

(def token->id
  "Map from a token string to its move id."
  (into {} (map-indexed (fn [i t] [t i])) tokens))

(defn id->token
  "The token string for a move id."
  [id]
  (nth tokens id))

(defn face-index
  "Index (0-5, order U R F D L B) of the face turned by move `id`."
  ^long [id]
  (quot (long id) 3))

(defn inverse-id
  "The move id of the inverse of move `id`."
  ^long [id]
  (let [id (long id)]
    (case (rem id 3)
      0 (inc (inc id))
      1 id
      2 (dec (dec id)))))

(defn inverse
  "The token that undoes `token`: `R` -> `R'`, `R'` -> `R`, `R2` -> `R2`."
  [token]
  (id->token (inverse-id (token->id token))))

(defn invert
  "The sequence of tokens that undoes the sequence `tokens`."
  [tokens]
  (mapv inverse (rseq (vec tokens))))

(defn parse
  "Parse a string of space-separated tokens into a vector of token strings.
  Blank input is the empty sequence. Throws `ex-info` on an unknown token."
  [s]
  (let [s (str/trim s)]
    (if (str/blank? s)
      []
      (let [ts (str/split s #"\s+")]
        (doseq [t ts]
          (when-not (contains? token->id t)
            (throw (ex-info (str "Invalid move token: " (pr-str t)) {:token t}))))
        ts))))

(defn unparse
  "Format a sequence of tokens as a single space-separated string."
  [tokens]
  (str/join " " tokens))

(defn parse-ids
  "Like [[parse]], but returns a vector of move ids."
  [s]
  (mapv token->id (parse s)))

(defn simplify
  "Merge adjacent moves of the same face in a sequence of tokens (`R R2` ->
  `R'`, `R R'` -> nothing), repeatedly. The result has the same effect on the
  cube and is never longer."
  [tokens]
  (let [quarters (fn [id] (inc (rem (long id) 3)))] ; 1, 2 or 3 clockwise quarter turns
    (reduce (fn [out t]
              (let [id  (long (token->id t))
                    top (peek out)]
                (if (and top (= (face-index (token->id top)) (face-index id)))
                  (let [turns (rem (+ (quarters (token->id top)) (quarters id)) 4)]
                    (if (zero? turns)
                      (pop out)
                      (conj (pop out) (id->token (+ (* 3 (face-index id)) (dec turns))))))
                  (conj out t))))
            []
            tokens)))
