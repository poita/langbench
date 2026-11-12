(ns datalog.plan
  "Compiles a rule into a join plan (a `datalog.join/Executor`).

  The plan follows the rules of semi-naive evaluation:

  * the variant for a *delta atom* reads that atom from its relation's delta
    and starts the join with it; the plain variant has no delta atom;
  * the remaining atoms are ordered greedily: next is the atom with the most
    bound arguments (constants or variables bound by earlier atoms), ties
    broken by body order;
  * an atom whose arguments are all bound becomes a membership test; any
    other atom with bound arguments is served by a hash index on exactly
    those columns (created on demand, and kept up to date by the relation);
  * negated atoms and comparisons are applied right after the first step at
    which all their variables are bound."
  (:require [datalog.join :as j]
            [datalog.storage :as st]
            [datalog.syntax :as syn])
  (:import (datalog.storage IRelation)))

(set! *warn-on-reflection* true)

(defn- slot-of ^long [^long spec] (- -1 spec))

(defn- atom-slots [specs]
  (into #{} (comp (filter neg?) (map slot-of)) specs))

(defn- resolve-rule
  "Replaces terms by specs (see `datalog.join`): constants by ids through
  `id-of`, variables by slot numbers; each `_` gets its own slot."
  [rule id-of]
  (let [slots (volatile! {})
        counter (volatile! 0)
        fresh! (fn [] (let [s @counter] (vswap! counter inc) s))
        spec (fn [t]
               (cond
                 (syn/anonymous? t) (- -1 (long (fresh!)))
                 (symbol? t) (- -1 (long (or (get @slots t)
                                             (let [s (fresh!)] (vswap! slots assoc t s) s))))
                 :else (long (id-of t))))
        atom* (fn [a] {:key (syn/atom-key a) :specs (mapv spec (:args a))})
        body (:body rule)
        pos (mapv #(atom* (:atom %)) (filter #(= :pos (:op %)) body))
        neg (mapv #(atom* (:atom %)) (filter #(= :neg (:op %)) body))
        cmps (mapv (fn [l] {:op (.indexOf ^java.util.List j/cmp-ops (:cmp l))
                            :specs [(spec (:left l)) (spec (:right l))]})
                   (filter #(= :cmp (:op %)) body))
        head (atom* (:head rule))]
    {:head head :pos pos :neg neg :cmps cmps :nvars @counter}))

(defn- order-atoms
  "Join order of the positive atoms (a vector of resolved atoms): the delta
  atom (if any) first, then by most bound arguments, ties in body order."
  [atoms delta-index]
  (let [bound-count (fn [bound {:keys [specs]}]
                      (count (filter #(or (>= (long %) 0) (contains? bound (slot-of %))) specs)))]
    (loop [remaining (vec (map-indexed vector atoms))
           bound #{}
           out []]
      (if (empty? remaining)
        out
        (let [pick (if (and (empty? out) delta-index)
                     (first (filter #(= delta-index (first %)) remaining))
                     (reduce (fn [best cand]
                               (if (> (bound-count bound (second cand))
                                      (bound-count bound (second best)))
                                 cand best))
                             remaining))
              [i a] pick]
          (recur (vec (remove #(= i (first %)) remaining))
                 (into bound (atom-slots (:specs a)))
                 (conj out (assoc a :delta? (and (empty? out) (some? delta-index))))))))))

(defn- make-step
  "Builds the `Step` for atom `a` given the set of already bound slots."
  [{:keys [specs delta? key]} bound rel-of filters]
  (let [^IRelation rel (rel-of key)
        arity (count specs)
        ;; Classify each column: bound (constant / earlier variable), fresh
        ;; (first occurrence here: binds), repeat (occurs again in the atom).
        [bound-cols binds repeats]
        (loop [c 0 seen #{} bc [] bi [] rp []]
          (if (== c arity)
            [bc bi rp]
            (let [s (long (nth specs c))]
              (cond
                (or (>= s 0) (contains? bound (slot-of s))) (recur (inc c) seen (conj bc [c s]) bi rp)
                (contains? seen (slot-of s)) (recur (inc c) seen bc bi (conj rp [c s]))
                :else (recur (inc c) (conj seen (slot-of s)) bc (conj bi [c (slot-of s)]) rp)))))
        ints* (fn [xs] (int-array xs))
        mk (fn [mode idx kcols checks]
             (j/->Step mode rel idx
                       (ints* (map second kcols)) (int-array (count kcols))
                       (ints* (map first binds)) (ints* (map second binds))
                       (ints* (map first checks)) (ints* (map second checks))
                       (object-array filters)))]
    (cond
      delta? (mk j/mode-delta nil [] (concat bound-cols repeats))
      (empty? bound-cols) (mk j/mode-scan nil [] repeats)
      (== (count bound-cols) arity) (mk j/mode-exists (.primary rel) bound-cols [])
      :else (mk j/mode-index (.indexOn rel (ints* (map first bound-cols))) bound-cols repeats))))

(defn compile-rule
  "Compiles `rule` (a map with :head and :body, see `datalog.syntax`) into an
  executor. `ctx` has `:rel-of` (predicate key -> relation) and `:id-of`
  (constant -> interned id). `delta-index` is the position, among the rule's
  positive body atoms in body order, of the atom to read from the delta, or
  nil for the plain variant."
  [rule {:keys [rel-of id-of]} delta-index]
  (let [{:keys [head pos neg cmps nvars]} (resolve-rule rule id-of)
        ordered (order-atoms pos delta-index)
        pending (concat
                 (for [{:keys [key specs]} neg]
                   {:vars (atom-slots specs)
                    :make #(j/->NegFilter (rel-of key) (int-array specs)
                                          (int-array (count specs)))})
                 (for [{:keys [op specs]} cmps]
                   {:vars (atom-slots specs)
                    :make #(j/->CmpFilter op (first specs) (second specs))}))
        ready? (fn [bound f] (every? bound (:vars f)))
        ;; filters needing no variables run before the first step
        pre (filter #(ready? #{} %) pending)
        pending (remove #(ready? #{} %) pending)
        [steps _ _]
        (reduce (fn [[steps bound pending] a]
                  (let [bound' (into bound (atom-slots (:specs a)))
                        fs (filter #(ready? bound' %) pending)
                        step (make-step a bound rel-of (map #((:make %)) fs))]
                    [(conj steps step) bound' (remove #(ready? bound' %) pending)]))
                [[] #{} pending]
                ordered)]
    (j/->Executor (object-array steps)
                  (int-array nvars)
                  (object-array (map #((:make %)) pre))
                  (int-array (:specs head))
                  (int-array (count (:specs head)))
                  (rel-of (:key head)))))

(defn positive-atom-keys
  "Predicate keys of the positive body atoms of `rule`, in body order."
  [rule]
  (into [] (comp (filter #(= :pos (:op %))) (map #(syn/atom-key (:atom %)))) (:body rule)))
