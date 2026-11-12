(ns rubiks.cubie
  "Cubie-level model of the cube: positions and orientations of the eight
  corners and twelve edges.

  A state is a map of four vectors of ints:

  * `:cp` - for each corner position, which corner cubie is there (0-7);
  * `:co` - for each corner position, the orientation (0-2) of that cubie;
  * `:ep` - for each edge position, which edge cubie is there (0-11);
  * `:eo` - for each edge position, the orientation (0-1) of that cubie.

  Corners are numbered URF UFL ULB UBR DFR DLF DBL DRB and edges UR UF UL UB DR
  DF DL DB FR FL BL BR (see [[corner-names]], [[edge-names]]). A corner is
  oriented (0) when its U or D sticker is on a U or D facelet; an edge is
  oriented (0) when its U/D sticker (F/B for the four middle-layer edges) is on
  a facelet of the same kind. With this convention only quarter turns of F and
  B flip edges, and only quarter turns of the other faces twist corners.

  The move effects here are *derived* from the facelet model in
  [[rubiks.facelet]] when the namespace loads, not typed in a second time."
  (:require [clojure.string :as str]
            [rubiks.facelet :as facelet]
            [rubiks.moves :as moves]))

(def corner-names ["URF" "UFL" "ULB" "UBR" "DFR" "DLF" "DBL" "DRB"])
(def edge-names ["UR" "UF" "UL" "UB" "DR" "DF" "DL" "DB" "FR" "FL" "BL" "BR"])

(defn- facelet-lists [s]
  (mapv (fn [t] (mapv facelet/index (str/split t #" "))) s))

(def ^:private corner-facelets
  "Facelets of each corner position; the U/D facelet comes first and the rest
  follow clockwise."
  (facelet-lists ["U9 R1 F3" "U7 F1 L3" "U1 L1 B3" "U3 B1 R3"
                  "D3 F9 R7" "D1 L9 F7" "D7 B9 L7" "D9 R9 B7"]))

(def ^:private edge-facelets
  "Facelets of each edge position; the U/D (or, in the middle layer, F/B)
  facelet comes first."
  (facelet-lists ["U6 R2" "U8 F2" "U4 L2" "U2 B2" "D6 R8" "D2 F8"
                  "D4 L8" "D8 B8" "F6 R4" "F4 L6" "B6 L4" "B4 R6"]))

(defn- owner-table
  "Vector over the 54 facelets of `[position index-in-position]` (nil for
  centres)."
  [facelets]
  (reduce (fn [acc [p fs]]
            (reduce (fn [acc [k f]] (assoc acc f [p k])) acc (map-indexed vector fs)))
          (vec (repeat 54 nil))
          (map-indexed vector facelets)))

(defn- derive-move
  "Effect of one move on a family of cubie positions (`n-orient` = 3 for
  corners, 2 for edges): `{:perm .. :twist ..}`, meaning that after the move
  position `p` holds what was at `(perm p)` with its orientation increased by
  `(twist p)` (mod `n-orient`)."
  [src facelets owner n-orient]
  (let [per-pos (vec (for [fs facelets]
                       (vec (for [[j f] (map-indexed vector fs)
                                  :let [[q k] (owner (src f))]]
                              [q (mod (- j k) n-orient)]))))]
    (doseq [r per-pos]
      (assert (apply = r) "move does not act consistently on a cubie"))
    {:perm  (mapv (comp first first) per-pos)
     :twist (mapv (comp second first) per-pos)}))

(def move-data
  "Effect of every move (indexed by move id) on the cubies:
  `{:cperm :ctwist :eperm :etwist}`, each a vector. After the move,
  `cp'[p] = cp[cperm[p]]` and `co'[p] = (co[cperm[p]] + ctwist[p]) mod 3`, and
  likewise for edges with modulus 2."
  (let [c-owner (owner-table corner-facelets)
        e-owner (owner-table edge-facelets)]
    (vec (for [src facelet/sources
               :let [c (derive-move src corner-facelets c-owner 3)
                     e (derive-move src edge-facelets e-owner 2)]]
           {:cperm (:perm c) :ctwist (:twist c)
            :eperm (:perm e) :etwist (:twist e)}))))

(def solved
  "The solved cube."
  {:cp (vec (range 8)) :co (vec (repeat 8 0))
   :ep (vec (range 12)) :eo (vec (repeat 12 0))})

;; ---------------------------------------------------------------------------
;; Applying moves (array based: scrambles can be a thousand moves long)

(def ^:private move-arrays
  (mapv (fn [m] (into {} (map (fn [[k v]] [k (int-array v)])) m)) move-data))

(defn- step!
  "Apply move `m` to the state held in `[cp co ep eo]`, writing into
  `[cp2 co2 ep2 eo2]`."
  [m ^ints cp ^ints co ^ints ep ^ints eo ^ints cp2 ^ints co2 ^ints ep2 ^ints eo2]
  (let [{:keys [^ints cperm ^ints ctwist ^ints eperm ^ints etwist]} (move-arrays m)]
    (dotimes [p 8]
      (let [q (aget cperm p)]
        (aset cp2 p (aget cp q))
        (aset co2 p (rem (+ (aget co q) (aget ctwist p)) 3))))
    (dotimes [p 12]
      (let [q (aget eperm p)]
        (aset ep2 p (aget ep q))
        (aset eo2 p (rem (+ (aget eo q) (aget etwist p)) 2))))))

(defn apply-move-ids
  "Apply a sequence of move ids to a state."
  [state ids]
  (let [a (into-array [(int-array (:cp state)) (int-array (:co state))
                       (int-array (:ep state)) (int-array (:eo state))])
        b (into-array [(int-array 8) (int-array 8) (int-array 12) (int-array 12)])
        [^objects a ^objects b]
        (reduce (fn [[^objects a ^objects b] id]
                  (step! id (aget a 0) (aget a 1) (aget a 2) (aget a 3)
                         (aget b 0) (aget b 1) (aget b 2) (aget b 3))
                  [b a])
                [a b]
                ids)]
    {:cp (vec (aget a 0)) :co (vec (aget a 1))
     :ep (vec (aget a 2)) :eo (vec (aget a 3))}))

(defn apply-moves
  "Apply a sequence of move tokens (see [[rubiks.moves]]) to a state."
  [state tokens]
  (apply-move-ids state (map moves/token->id tokens)))

(defn apply-move
  "Apply one move token to a state."
  [state token]
  (apply-moves state [token]))

(defn scramble
  "The state reached from a solved cube by the sequence of move tokens."
  [tokens]
  (apply-moves solved tokens))

(defn solved?
  "True when `state` is the solved cube."
  [state]
  (= state solved))

;; ---------------------------------------------------------------------------
;; Conversion to and from facelet strings

(def ^:private home-faces
  "The face letters of each cubie's stickers (first = primary), by cubie."
  (let [f (fn [fs] (mapv (fn [facelets] (mapv #(nth facelet/solved %) facelets)) fs))]
    {:corner (f corner-facelets) :edge (f edge-facelets)}))

(defn ->facelets
  "The facelet string of a cubie state."
  [{:keys [cp co ep eo]}]
  (let [out (char-array facelet/solved)]
    (doseq [[positions facelets perm ori n kind]
            [[8 corner-facelets cp co 3 :corner] [12 edge-facelets ep eo 2 :edge]]
            p (range positions)
            [j f] (map-indexed vector (nth facelets p))]
      (aset out f (get-in home-faces [kind (nth perm p) (mod (- j (nth ori p)) n)])))
    (String. out)))

(defn from-facelets
  "The cubie state of a facelet string. Throws `ex-info` if the string is not
  made of recognisable cubies (this does not check solvability; see
  [[solvable?]])."
  [^String s]
  (when-not (= 54 (count s))
    (throw (ex-info "A facelet string must have 54 characters" {:string s})))
  (let [colours (fn [fs] (mapv #(.charAt s (long %)) fs))
        find-cubie
        (fn [kind fs]
          (let [cs (colours fs)
                n (count cs)
                homes (home-faces kind)
                ;; try each rotation of the colours; the cubie is recognised
                ;; when the rotation matches a home sticker list
                hit (first (for [o (range n)
                                 :let [rot (vec (for [i (range n)] (cs (mod (+ o i) n))))]
                                 [c home] (map-indexed vector homes)
                                 :when (= rot home)]
                             [c o]))]
            (or hit (throw (ex-info "Unrecognised cubie" {:kind kind :colours cs})))))
        corners (mapv #(find-cubie :corner %) corner-facelets)
        edges   (mapv #(find-cubie :edge %) edge-facelets)]
    {:cp (mapv first corners) :co (mapv second corners)
     :ep (mapv first edges)   :eo (mapv second edges)}))

;; ---------------------------------------------------------------------------
;; Validity

(defn- parity
  "Parity (0 or 1) of the permutation `p`."
  [p]
  (rem (count (for [i (range (count p)) j (range i) :when (> (p j) (p i))] 1)) 2))

(defn solvable?
  "True when `state` is a legal, reachable cube state: its permutations are
  permutations, corner twists sum to 0 mod 3, edge flips sum to 0 mod 2 and
  the corner and edge permutations have equal parity."
  [{:keys [cp co ep eo]}]
  (and (= (range 8) (sort cp))
       (= (range 12) (sort ep))
       (every? #(<= 0 % 2) co)
       (every? #(<= 0 % 1) eo)
       (zero? (mod (reduce + co) 3))
       (zero? (mod (reduce + eo) 2))
       (= (parity cp) (parity ep))))
