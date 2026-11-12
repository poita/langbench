(ns rubiks.phases
  "The four phases of Thistlethwaite's algorithm.

  Each phase moves the cube from one subgroup of the cube group into the next,
  using only the moves that keep it inside the subgroup it is already in:

  | phase | allowed moves                    | goal                                   |
  |-------|----------------------------------|----------------------------------------|
  | 1     | all 18                           | every edge oriented                    |
  | 2     | all but quarter turns of F and B | corners oriented, E-slice edges home   |
  | 3     | U, D turns and L2 R2 F2 B2       | corners in the half-turn group, M-slice edges home |
  | 4     | the six half turns               | solved                                 |

  A phase is `{:name :moves :coordinates}`: `:moves` are move ids and
  `:coordinates` a vector of [[rubiks.coords]] coordinates whose mixed-radix
  combination (first = most significant) identifies the cube's coset of the
  phase's goal subgroup. The goal coordinate is that of the solved cube."
  (:require [rubiks.coords :as coords]
            [rubiks.moves :as moves]))

(defn- ids [tokens] (mapv moves/token->id tokens))

(def phases
  [{:name        "phase 1: edge orientation"
    :moves       (vec (range 18))
    :coordinates [coords/edge-orientation]}

   {:name        "phase 2: corner orientation and E slice"
    :moves       (ids ["U" "U2" "U'" "D" "D2" "D'" "L" "L2" "L'" "R" "R2" "R'" "F2" "B2"])
    :coordinates [coords/corner-orientation coords/e-slice-positions]}

   {:name        "phase 3: corner classes and M slice"
    :moves       (ids ["U" "U2" "U'" "D" "D2" "D'" "L2" "R2" "F2" "B2"])
    :coordinates [coords/corner-class coords/m-slice-positions]}

   {:name        "phase 4: half-turn group"
    :moves       (ids ["U2" "D2" "L2" "R2" "F2" "B2"])
    :coordinates [coords/corner-permutation
                  coords/m-slice-permutation
                  coords/s-slice-permutation
                  coords/e-slice-permutation]}])
