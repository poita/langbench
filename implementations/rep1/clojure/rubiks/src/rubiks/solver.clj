(ns rubiks.solver
  "Thistlethwaite's algorithm: solve a cube in four phases, each by greedy
  descent on an exact distance table (see [[rubiks.tables]]).

  Because every phase's table is exact, each phase takes the minimum possible
  number of moves, and a solution never exceeds 7 + 10 + 13 + 15 = 45 moves.
  No search happens while solving: a phase repeatedly takes an allowed move
  whose successor is one step closer to the phase goal."
  (:require [rubiks.cubie :as cubie]
            [rubiks.moves :as moves]
            [rubiks.tables :as tables]))

(defn- descend
  "Moves (as ids) taking `state` to the goal of `phase` by greedy descent."
  [phase state]
  (let [start (tables/coordinate phase state)]
    (when (neg? (tables/distance phase start))
      (throw (ex-info "Cube state cannot be solved" {:phase (:name phase)})))
    (loop [c start, out []]
      (let [d (tables/distance phase c)]
        (if (zero? d)
          out
          (let [m (first (filter #(= (dec d) (tables/distance phase (tables/next-coordinate phase c %)))
                                 (:moves phase)))]
            (recur (tables/next-coordinate phase c m) (conj out m))))))))

(defn solve-phases
  "Solve `state`, returning one vector of tokens per phase.
  The first argument may be omitted, in which case the shared
  [[rubiks.tables/default-tables]] are used."
  ([state] (solve-phases @tables/default-tables state))
  ([phase-tables state]
   (when-not (cubie/solvable? state)
     (throw (ex-info "Cube state is not solvable" {:state state})))
   (loop [[phase & more] phase-tables, state state, out []]
     (if phase
       (let [ids (descend phase state)]
         (recur more (cubie/apply-move-ids state ids) (conj out (mapv moves/id->token ids))))
       out))))

(defn solve
  "A vector of move tokens that solves the cubie `state`, at most 45 moves
  long (adjacent moves of one face are merged). Throws `ex-info` if the state is not a solvable cube.

  `(solve state)` uses the shared default tables (built on first use, which
  takes about a second); `(solve phase-tables state)` takes tables from
  [[rubiks.tables/build]]."
  ([state] (solve @tables/default-tables state))
  ([phase-tables state]
   (moves/simplify (into [] cat (solve-phases phase-tables state)))))

(defn solve-scramble
  "Solve the cube obtained from a solved cube by the scramble `tokens`."
  ([tokens] (solve-scramble @tables/default-tables tokens))
  ([phase-tables tokens]
   (solve phase-tables (cubie/scramble tokens))))
