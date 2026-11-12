(ns rubiks.tables
  "Exact distance tables for the four phases.

  For each phase, a breadth-first search from the goal coordinate over the
  phase's coordinate space gives the exact number of phase moves needed from
  every coordinate value. Because each phase's move set is closed under
  inversion the search can run forwards from the goal. The tables are built
  once ([[default-tables]]) and then only read."
  (:require [rubiks.cubie :as cubie]
            [rubiks.phases :as phases]))

(defn- move-table
  "Transition table of one coordinate: an int array indexed by
  `move-id * radix + digit` giving the digit after the move (-1 for moves
  outside the phase)."
  ^ints [{:keys [radix step]} move-ids]
  (let [radix (long radix)
        t (int-array (* 18 radix) -1)]
    (doseq [m move-ids, d (range radix)]
      (aset t (int (+ (* (long m) radix) (long d))) (int (step d m))))
    t))

(defn- build-phase
  [{:keys [moves coordinates] :as phase}]
  (let [radices (mapv :radix coordinates)
        n       (count radices)
        strides (vec (reverse (butlast (reductions * 1 (reverse radices)))))
        size    (long (reduce * radices))
        tables  (object-array (map #(move-table % moves) coordinates))
        radix-a (long-array radices)
        stride-a (long-array strides)
        moves-a (int-array moves)
        nmoves  (alength moves-a)
        goal    (long (reduce + (map (fn [c s] (* (long ((:digit c) cubie/solved)) (long s)))
                                     coordinates strides)))
        dist    (byte-array size (byte -1))
        queue   (int-array size)
        digits  (long-array n)]
    (aset dist (int goal) (byte 0))
    (aset queue 0 (int goal))
    (loop [head 0, tail 1]
      (if (= head tail)
        (assoc phase
               :radices radices :strides strides :tables (vec tables)
               :goal goal :dist dist :size size
               :max-depth (long (aget dist (int (aget queue (dec tail))))))
        (let [c (long (aget queue head))
              d (long (aget dist (int c)))]
          (dotimes [i n]
            (aset digits i (rem (quot c (aget stride-a i)) (aget radix-a i))))
          (let [tail
                (loop [k 0, tail tail]
                  (if (= k nmoves)
                    tail
                    (let [m (long (aget moves-a k))
                          nc (loop [i 0, acc 0]
                               (if (= i n)
                                 acc
                                 (let [^ints t (aget tables i)
                                       nd (long (aget t (int (+ (* m (aget radix-a i)) (aget digits i)))))]
                                   (recur (inc i) (+ acc (* nd (aget stride-a i)))))))]
                      (if (neg? (aget dist (int nc)))
                        (do (aset dist (int nc) (byte (inc d)))
                            (aset queue (int tail) (int nc))
                            (recur (inc k) (inc tail)))
                        (recur (inc k) tail)))))]
            (recur (inc head) tail)))))))

(defn build
  "Build the distance tables of all four phases (in parallel). Returns a
  vector of phase maps: the entries of [[rubiks.phases/phases]] extended with
  `:radices :strides :tables :goal :dist :size :max-depth`."
  []
  (vec (pmap build-phase phases/phases)))

(def default-tables
  "A delay of the tables built by [[build]], shared by all callers."
  (delay (build)))

(defn coordinate
  "The phase coordinate (a long) of a cubie state."
  ^long [phase state]
  (reduce + (map (fn [c s] (* (long ((:digit c) state)) (long s)))
                 (:coordinates phase) (:strides phase))))

(defn distance
  "Number of phase moves needed from coordinate `c`, or -1 if `c` cannot reach
  the goal."
  ^long [phase ^long c]
  (long (aget ^bytes (:dist phase) (int c))))

(defn next-coordinate
  "The coordinate reached from `c` by move `m` (a move id of the phase)."
  ^long [phase ^long c ^long m]
  (let [radices (:radices phase) strides (:strides phase) tables (:tables phase)]
    (loop [i 0, acc 0]
      (if (= i (count radices))
        acc
        (let [r (long (nth radices i)) s (long (nth strides i))
              digit (rem (quot c s) r)
              ^ints t (nth tables i)]
          (recur (inc i) (+ acc (* s (long (aget t (int (+ (* m r) digit))))))))))))
