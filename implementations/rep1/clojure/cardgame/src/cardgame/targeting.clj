(ns cardgame.targeting
  "Targets: specifications, legality and enumeration (SPEC section 12).

  A *token* names a target: `:A`/`:B` for a player, an oid for an object,
  `[:c cid]` for a Chain entry."
  (:require [cardgame.state :as st]
            [cardgame.board :as board]
            [cardgame.query :as q]))

(defn- protected?
  "The spectral rule (12.2) for a unit `oid` and an ability controlled by
  `ctrl`."
  [g oid ctrl]
  (and (board/has-kw? g oid "spectral")
       (not= (board/ctrl g oid) ctrl)))

(defn- unit-ok? [g c oid fs ctrl]
  (let [o (board/obj g oid)]
    (and (= :field (:zone o))
         (= :unit (:type (:def o)))
         (q/filters-hold? c o fs)
         (not (protected? g oid ctrl)))))

(defn legal-target?
  "Is `tok` a legal target for `tspec` of an ability controlled by `ctrl`
  whose source is `src`?  `announcing` is the cid of the entry being
  announced or resolved (never a legal `(chained)` target)."
  [g tspec tok ctrl src announcing]
  (let [c (board/ctx g {:ctrl ctrl :src src})
        kind (first tspec)]
    (case kind
      :player (keyword? tok)
      :chained (and (vector? tok)
                    (not= (second tok) announcing)
                    (boolean (some #(= (:cid %) (second tok)) (:chain @g))))
      :any (or (keyword? tok)
               (and (integer? tok) (some? (board/obj g tok))
                    (unit-ok? g c tok (second tspec) ctrl)))
      :unit (and (integer? tok) (some? (board/obj g tok))
                 (unit-ok? g c tok (second tspec) ctrl))
      :relic (and (integer? tok)
                  (let [o (board/obj g tok)]
                    (and o (= :field (:zone o)) (= :relic (:type (:def o)))
                         (q/filters-hold? c o (second tspec)))))
      :ashcard (and (integer? tok)
                    (let [o (board/obj g tok)]
                      (and o (= :ash (:zone o)) (q/filters-hold? c o (second tspec))))))))

(defn candidates
  "Every legal target for `tspec`, in ascending target-key order."
  [g tspec ctrl src announcing]
  (let [c (board/ctx g {:ctrl ctrl :src src})
        units (fn [fs] (filterv #(not (protected? g % ctrl))
                                (q/field-objects c :unit :all fs)))]
    (case (first tspec)
      :player [:A :B]
      :chained (->> (:chain @g) (map :cid) (remove #{announcing}) sort (mapv (fn [x] [:c x])))
      :any (into [:A :B] (units (second tspec)))
      :unit (units (second tspec))
      :relic (q/field-objects c :relic :all (second tspec))
      :ashcard (q/zone-objects c :ash :all (second tspec)))))

(defn tuples
  "All tuples of distinct legal targets for `tspecs`, in ascending
  lexicographic target-key order."
  [g tspecs ctrl src announcing]
  (let [cands (mapv #(candidates g % ctrl src announcing) tspecs)]
    (letfn [(go [i chosen]
              (if (= i (count cands))
                [chosen]
                (mapcat (fn [t] (when-not (some #{t} chosen) (go (inc i) (conj chosen t))))
                        (nth cands i))))]
      (go 0 []))))

(defn auto-targets
  "The targets chosen automatically for a trigger (13.4): the first
  candidate distinct from earlier choices, per specification.  Returns nil
  when some specification has no candidate."
  [g tspecs ctrl src]
  (loop [ts tspecs, chosen []]
    (if-let [[t & more] (seq ts)]
      (if-let [pick (first (remove (set chosen) (candidates g t ctrl src nil)))]
        (recur more (conj chosen pick))
        nil)
      chosen)))
