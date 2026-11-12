(ns rubiks.coords
  "Coordinates: small integers that describe one aspect of a cube state.

  Every coordinate is a map
  `{:name .. :radix n :digit (fn [state] d) :step (fn [d move-id] d')}`:

  * `:digit` reads the coordinate (0 <= d < radix) off a cubie state;
  * `:step` says how the coordinate changes when move `move-id` is applied. It
    is only meaningful for the moves of the phase the coordinate is used in
    (see [[rubiks.phases]]) and only when the state satisfies that phase's
    preconditions; it is checked against [[rubiks.cubie]] by the tests.

  A *phase coordinate* is built from several of these (mixed radix), which
  keeps the move tables tiny: the big spaces are the product of small ones."
  (:require [rubiks.cubie :as cubie]
            [rubiks.moves :as moves]))

(defn- eperm [m] (:eperm (cubie/move-data m)))
(defn- cperm [m] (:cperm (cubie/move-data m)))

;; ---------------------------------------------------------------------------
;; Phase 1: orientation of the edges (2048 values)

(defn- eo-encode [eo] (reduce (fn [acc i] (+ acc (bit-shift-left (long (nth eo i)) i))) 0 (range 11)))

(defn- eo-decode [^long c]
  (let [bits (mapv #(bit-and 1 (bit-shift-right c %)) (range 11))]
    (conj bits (rem (reduce + bits) 2))))

(def edge-orientation
  "Orientation of the edges, 11 free bits: 2^11 = 2048 values. 0 = all oriented."
  {:name  :edge-orientation
   :radix 2048
   :digit (fn [state] (eo-encode (:eo state)))
   :step  (fn [d m]
            (let [{:keys [eperm etwist]} (cubie/move-data m)
                  eo (eo-decode d)]
              (eo-encode (mapv (fn [p] (rem (+ (long (eo (eperm p))) (long (etwist p))) 2)) (range 12)))))})

;; ---------------------------------------------------------------------------
;; Phase 2: corner orientation (2187) and E-slice edge positions (495)

(defn- co-encode [co] (reduce (fn [acc i] (+ (* 3 (long acc)) (long (nth co i)))) 0 (reverse (range 7))))

(defn- co-decode [^long c]
  (let [ds (loop [c c, i 0, out []]
             (if (= i 7) out (recur (quot c 3) (inc i) (conj out (rem c 3)))))]
    (conj ds (rem (- 3 (rem (reduce + ds) 3)) 3))))

(def corner-orientation
  "Orientation of the corners, 7 free base-3 digits: 3^7 = 2187 values."
  {:name  :corner-orientation
   :radix 2187
   :digit (fn [state] (co-encode (:co state)))
   :step  (fn [d m]
            (let [{:keys [cperm ctwist]} (cubie/move-data m)
                  co (co-decode d)]
              (co-encode (mapv (fn [p] (rem (+ (long (co (cperm p))) (long (ctwist p))) 3)) (range 8)))))})

(defn- combinations-table
  "All `n`-bit masks with `k` bits set, in increasing order, and the inverse
  map as an int array of size 2^n."
  [n k]
  (let [masks (vec (filter #(= k (Long/bitCount (long %))) (range (bit-shift-left 1 n))))
        index (int-array (bit-shift-left 1 n) -1)]
    (doseq [[i m] (map-indexed vector masks)] (aset index (int m) (int i)))
    {:masks masks :index index}))

(defn- subset-coordinate
  "Coordinate describing which `k` of the first `n` edge positions hold an
  edge cubie from `cubies`: C(n, k) values. The state is assumed to have all
  `k` of those cubies among the first `n` positions."
  [name n k cubies]
  (let [{:keys [masks ^ints index]} (combinations-table n k)
        cubies (set cubies)
        mask-of (fn [state] (reduce (fn [acc p] (if (cubies (nth (:ep state) p))
                                                  (bit-set acc p) acc))
                                    0 (range n)))]
    {:name  name
     :radix (count masks)
     :digit (fn [state] (aget index (int (mask-of state))))
     :step  (fn [d m]
              (let [mask (long (masks d)) perm (eperm m)]
                (aget index (int (reduce (fn [acc p] (if (bit-test mask (long (perm p))) (bit-set acc p) acc))
                                         0 (range n))))))}))

(def e-slice-positions
  "Which 4 of the 12 edge positions hold the E-slice edges (FR FL BL BR):
  C(12,4) = 495 values."
  (subset-coordinate :e-slice-positions 12 4 [8 9 10 11]))

;; ---------------------------------------------------------------------------
;; Permutations of 8 corners, and the half-turn group acting on them

(defn- rank
  "Lehmer-code rank of the permutation held in int array `a` (length n)."
  ^long [^ints a]
  (let [n (alength a)]
    (loop [i 0, r 0]
      (if (= i n)
        r
        (let [smaller (loop [j (inc i), c 0]
                        (if (< j n) (recur (inc j) (if (< (aget a j) (aget a i)) (inc c) c)) c))]
          (recur (inc i) (+ (* r (- n i)) smaller)))))))

(defn- unrank
  "Inverse of [[rank]]: the permutation of length `n` with rank `r`."
  ^ints [^long n ^long r]
  (let [digits (loop [i 1, r r, out ()]   ; factorial-base digits, most significant first
                 (if (> i n) out (recur (inc i) (quot r i) (conj out (rem r i)))))
        avail (java.util.ArrayList. ^java.util.Collection (range n))
        out (int-array n)]
    (loop [i 0, ds digits]
      (when (seq ds)
        (aset out i (int (.remove avail (int (first ds)))))
        (recur (inc i) (rest ds))))
    out))

(def ^:private half-turn-ids (mapv moves/token->id ["U2" "D2" "L2" "R2" "F2" "B2"]))

(defn- compose-right
  "Permutation `p` followed by a move with position source table `src`
  (so `result[i] = p[src[i]]`)."
  ^ints [^ints p src]
  (let [out (int-array 8)]
    (dotimes [i 8] (aset out i (aget p (int (nth src i)))))
    out))

(defn- compose-left
  "Relabel the cubies of `p` by the permutation `g`: `result[i] = g[p[i]]`."
  ^ints [^ints p g]
  (let [out (int-array 8)]
    (dotimes [i 8] (aset out i (int (nth g (aget p i)))))
    out))

(def ^:private identity8 (int-array (range 8)))

(def ^:private corner-classes
  "Partition of the 40320 corner permutations into 420 classes of 96, where
  two permutations are equivalent when they differ by a relabelling of the
  cubies by an element of the half-turn group. `:class-of` maps a permutation
  rank to its class (the class containing the identity is 0); `:reps` holds one
  representative permutation per class."
  (delay
    (let [class-of (int-array 40320 -1)
          gens (map cperm half-turn-ids)
          reps (java.util.ArrayList.)]
      (dotimes [r 40320]
        (when (neg? (aget class-of r))
          (let [id (.size reps)]
            (.add reps (unrank 8 r))
            (aset class-of r id)
            (loop [stack (list r)]
              (when (seq stack)
                (let [p (unrank 8 (first stack))
                      fresh (for [g gens
                                  :let [q (rank (compose-left p g))]
                                  :when (neg? (aget class-of q))]
                              (do (aset class-of q id) q))]
                  (recur (into (rest stack) (distinct fresh)))))))))
      {:class-of class-of :reps (vec reps)})))

(def ^:private half-turn-group
  "The 96 corner permutations generated by half turns (the identity first) and
  a map from permutation rank to index in that list."
  (delay
    (let [index (int-array 40320 -1)
          gens (map cperm half-turn-ids)]
      (aset index (rank identity8) 0)
      (loop [elems [identity8], i 0]
        (if (= i (count elems))
          {:elems elems :index index}
          (recur (reduce (fn [es g]
                           (let [q (compose-right (elems i) g), r (rank q)]
                             (if (neg? (aget index r))
                               (do (aset index r (count es)) (conj es q))
                               es)))
                         elems gens)
                 (inc i)))))))

(def corner-class
  "The class of the corner permutation modulo the 96 half-turn permutations:
  8!/96 = 420 values; 0 means the corners are in the half-turn group."
  {:name  :corner-class
   :radix 420
   :digit (fn [state]
            (let [{:keys [^ints class-of]} @corner-classes]
              (aget class-of (int (rank (int-array (:cp state)))))))
   :step  (fn [d m]
            (let [{:keys [^ints class-of reps]} @corner-classes]
              (aget class-of (int (rank (compose-right (reps d) (cperm m)))))))})

(def m-slice-positions
  "Which 4 of the 8 U/D-layer edge positions hold the M-slice edges (UF UB DF
  DB): C(8,4) = 70 values."
  (subset-coordinate :m-slice-positions 8 4 [1 3 5 7]))

(def corner-permutation
  "Which of the 96 half-turn permutations the corner permutation is."
  {:name  :corner-permutation
   :radix 96
   :digit (fn [state]
            (let [{:keys [^ints index]} @half-turn-group
                  i (aget index (int (rank (int-array (:cp state)))))]
              (when (neg? i) (throw (ex-info "Corners are not in the half-turn group" {})))
              i))
   :step  (fn [d m]
            (let [{:keys [elems ^ints index]} @half-turn-group]
              (aget index (int (rank (compose-right (elems d) (cperm m)))))))})

(defn- slice-permutation
  "The arrangement of the four edges of one slice within that slice's four
  positions: 4! = 24 values."
  [name positions]
  (let [local (zipmap positions (range))]
    {:name  name
     :radix 24
     :digit (fn [state]
              (rank (int-array (map #(local (nth (:ep state) %)) positions))))
     :step  (fn [d m]
              (let [old (unrank 4 d) perm (eperm m)]
                (rank (int-array (for [pos positions] (aget old (int (local (perm pos)))))))))}))

(def m-slice-permutation (slice-permutation :m-slice-permutation [1 3 5 7]))
(def s-slice-permutation (slice-permutation :s-slice-permutation [0 2 4 6]))
(def e-slice-permutation (slice-permutation :e-slice-permutation [8 9 10 11]))
