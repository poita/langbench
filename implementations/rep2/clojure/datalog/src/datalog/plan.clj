(ns datalog.plan
  "Compiles rules into join plans and executable closures.

  [[lower-rule]] renames the terms of a parsed rule into the engine's
  internal form (constants become ranks, variables become numbered slots of an
  environment `long-array`).  [[compile-variant]] turns a lowered rule into a
  function that runs one *variant* of the rule:

  * an optional atom of the body is the *delta atom*: it reads only a range of
    rows of its relation (the tuples new in the previous round);
  * the plan orders the positive atoms as an indexed nested-loop join: the
    delta atom first, then repeatedly the atom with the most bound arguments
    (constants or already bound variables), ties in body order;
  * negated atoms and comparisons are checked as soon as all their variables
    are bound;
  * every solution adds the instantiated head to the head relation."
  (:require [datalog.analysis :as analysis]
            [datalog.relation :as rel])
  (:import (clojure.lang IPersistentVector LazilyPersistentVector)
           (java.util ArrayList)))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Lowering

(defn lower-rule
  "Lowers `rule` (`{:head atom :body [literal ...]}`, see [[datalog.parser]])
  using `rank` (a map from constants to ranks).

  A source is `[:c rank]` or `[:v slot]`.  Returns

      {:head    {:pid pred-id :args [source ...]}
       :atoms   [{:pid .. :args [source ...]} ...]     ; positive body atoms
       :filters [{:kind :neg :pid .. :args [..] :vars #{slot}}
                 {:kind :cmp :op .. :left source :right source :vars #{slot}}]
       :nslots  n}"
  [{:keys [head body]} rank]
  (let [slots (volatile! {})
        src (fn [t]
              (if (symbol? t)
                [:v (or (@slots t)
                        (let [i (count @slots)] (vswap! slots assoc t i) i))]
                [:c (rank t)]))
        atom* (fn [a] {:pid (analysis/pred-id a) :args (mapv src (:args a))})
        vars-of (fn [& srcs] (into #{} (comp (filter #(= :v (first %))) (map second)) srcs))
        head* (atom* head)
        lits (for [lit body]
               (cond
                 (= :cmp (:kind lit))
                 (let [l (src (:left lit)) r (src (:right lit))]
                   {:kind :cmp :op (:op lit) :left l :right r :vars (vars-of l r)})
                 (:negated? lit)
                 (let [a (atom* lit)]
                   (assoc a :kind :neg :vars (apply vars-of (:args a))))
                 :else (assoc (atom* lit) :kind :pos)))]
    {:head head*
     :atoms (vec (filter #(= :pos (:kind %)) lits))
     :filters (vec (remove #(= :pos (:kind %)) lits))
     :nslots (count @slots)}))

;; ---------------------------------------------------------------------------
;; Join planning

(defn- bound-count [atom bound]
  (count (filter (fn [[k v]] (or (= k :c) (contains? bound v))) (:args atom))))

(defn join-order
  "The order in which the positive `atoms` are joined, as a vector of indexes
  into `atoms`: `delta` (an index or nil) first, then repeatedly the atom with
  the most bound arguments, ties broken by body order."
  [atoms delta]
  (let [vars-of (fn [a] (into #{} (comp (filter #(= :v (first %))) (map second)) (:args a)))]
    (loop [order (if delta [delta] [])
           bound (if delta (vars-of (atoms delta)) #{})
           remaining (vec (remove #{delta} (range (count atoms))))]
      (if (empty? remaining)
        order
        (let [best (reduce (fn [b i]
                             (if (> (bound-count (atoms i) bound) (bound-count (atoms b) bound)) i b))
                           (first remaining) (rest remaining))]
          (recur (conj order best)
                 (into bound (vars-of (atoms best)))
                 (vec (remove #{best} remaining))))))))

(defn plan-steps
  "Builds the step list of a variant of `rule` with delta atom `delta` (or
  nil).  Each step is

      {:atom atom, :mode :delta | :index | :scan,
       :key [source ...]          ; :index only: sources of the bound positions
       :key-pos [pos ...]         ; :index only: those positions
       :const-checks [[pos rank]] ; :delta only
       :assign [[pos slot]] :check [[pos slot]]
       :filters [filter ...]}     ; applied after the atom is matched

  and the result is `{:pre [filter ...] :steps [step ...]}` where `:pre` are
  the filters without variables, to be checked before any atom."
  [{:keys [atoms filters]} delta]
  (let [order (join-order atoms delta)
        ready (fn [pending bound] (group-by #(every? bound (:vars %)) pending))
        {pre true pending false} (ready filters #{})]
    (loop [order order, bound #{}, pending (vec pending), steps []]
      (if-let [[i & more] (seq order)]
        (let [atom (atoms i)
              delta? (and delta (== i delta))
              ;; positions bound before this atom
              bound-pos (when-not delta?
                          (keep-indexed (fn [pos [k v]]
                                          (when (or (= k :c) (contains? bound v)) [pos [k v]]))
                                        (:args atom)))
              bound-pos-set (set (map first bound-pos))
              ;; for the rest: first occurrence of an unbound variable assigns,
              ;; later occurrences in the same atom check
              [assign check]
              (loop [pos 0, seen #{}, assign [], check []]
                (if (== pos (count (:args atom)))
                  [assign check]
                  (let [[k v] ((:args atom) pos)]
                    (cond
                      (bound-pos-set pos) (recur (inc pos) seen assign check)
                      (= k :c) (recur (inc pos) seen assign check) ; delta constant, see below
                      (seen v) (recur (inc pos) seen assign (conj check [pos v]))
                      :else (recur (inc pos) (conj seen v) (conj assign [pos v]) check)))))
              bound' (into bound (comp (filter #(= :v (first %))) (map second)) (:args atom))
              {now true later false} (ready pending bound')
              step (cond-> {:atom atom :assign assign :check check :filters (vec now)}
                     delta? (assoc :mode :delta
                                   :const-checks (vec (keep-indexed
                                                       (fn [pos [k v]] (when (= k :c) [pos v]))
                                                       (:args atom))))
                     (and (not delta?) (seq bound-pos))
                     (assoc :mode :index
                            :key-pos (mapv first bound-pos)
                            :key (mapv second bound-pos))
                     (and (not delta?) (empty? bound-pos)) (assoc :mode :scan))]
          (recur more bound' (vec later) (conj steps step)))
        {:pre (vec pre) :steps steps}))))

;; ---------------------------------------------------------------------------
;; Compilation to closures

(defn- getter-arrays
  "Encodes `sources` as two long arrays: for each i, `slots[i]` is the slot of
  a variable or -1 for a constant, whose rank is then `vals[i]`."
  [sources]
  (let [n (count sources)
        slots (long-array n)
        vals (long-array n)]
    (doseq [[i [k v]] (map-indexed vector sources)]
      (if (= k :v)
        (aset slots i (long v))
        (do (aset slots i -1) (aset vals i (long v)))))
    [slots vals]))

(defn- tuple-builder
  "A function from environment to a new tuple built from `sources`, sharing
  boxed `Long`s from `boxed` (an array indexed by rank)."
  [sources ^objects boxed]
  (let [[^longs slots ^longs vals] (getter-arrays sources)
        n (alength slots)]
    (fn [^longs env]
      (let [a (object-array n)]
        (dotimes [i n]
          (let [s (aget slots i)
                v (if (neg? s) (aget vals i) (aget env s))]
            (aset a i (aget boxed v))))
        (LazilyPersistentVector/createOwning a)))))

(defn- compile-filter [{:keys [kind] :as f} relations boxed]
  (case kind
    :neg (let [r (relations (:pid f))
               build (tuple-builder (:args f) boxed)]
           (fn [env] (not (rel/member? r (build env)))))
    :cmp (let [[lk lv] (:left f), [rk rv] (:right f)
               lc? (= lk :c), rc? (= rk :c)
               lv (long lv), rv (long rv)
               op (:op f)]
           (fn [^longs env]
             (let [l (if lc? lv (aget env lv))
                   r (if rc? rv (aget env rv))]
               (case op
                 := (== l r)
                 :!= (not (== l r))
                 :< (< l r)
                 :<= (<= l r)
                 :> (> l r)
                 :>= (>= l r)))))))

(defn- all-of
  "Conjunction of predicates `fs` on the environment; nil when empty."
  [fs]
  (case (count fs)
    0 nil
    1 (first fs)
    (let [^objects arr (object-array fs)
          n (alength arr)]
      (fn [env]
        (loop [i 0]
          (or (== i n)
              (and ((aget arr i) env) (recur (inc i)))))))))

(defn- key-builder
  "A function from environment to the index key for `sources`."
  [sources ^objects boxed]
  (let [[^longs slots ^longs vals] (getter-arrays sources)
        n (alength slots)]
    (if (== n 1)
      (let [s (aget slots 0) v (aget vals 0)]
        (if (neg? s)
          (let [k (aget boxed v)] (fn [_] k))
          (fn [^longs env] (aget boxed (aget env s)))))
      (fn [^longs env]
        (let [a (object-array n)]
          (dotimes [i n]
            (let [s (aget slots i)
                  v (if (neg? s) (aget vals i) (aget env s))]
              (aset a i (aget boxed v))))
          (LazilyPersistentVector/createOwning a))))))

(defn- matcher
  "A function `(env tuple) -> boolean` performing the constant checks, the
  variable assignments and the repeated-variable checks of a step."
  [{:keys [const-checks assign check]}]
  (let [cpos (long-array (map first const-checks))
        cval (long-array (map second const-checks))
        apos (long-array (map first assign))
        aslot (long-array (map second assign))
        kpos (long-array (map first check))
        kslot (long-array (map second check))
        nc (alength cpos), na (alength apos), nk (alength kpos)]
    (fn [^longs env tuple]
      (let [^IPersistentVector t tuple]
        (and (loop [k 0]
               (or (== k nc)
                   (and (== (long (.nth t (int (aget cpos k)))) (aget cval k))
                        (recur (inc k)))))
             (do (dotimes [k na]
                   (aset env (aget aslot k) (long (.nth t (int (aget apos k))))))
                 true)
             (loop [k 0]
               (or (== k nk)
                   (and (== (long (.nth t (int (aget kpos k)))) (aget env (aget kslot k)))
                        (recur (inc k)))))))))) 

(defn- compile-step
  "Wraps `next` (a function of the environment) into the closure running one
  join step."
  [{:keys [mode atom filters] :as step} relations boxed ^longs delta-range next]
  (let [r (relations (:pid atom))
        match (matcher step)
        test (all-of (mapv #(compile-filter % relations boxed) filters))
        ;; called for each candidate tuple
        visit (if test
                (fn [env t] (when (and (match env t) (test env)) (next env)))
                (fn [env t] (when (match env t) (next env))))]
    (case mode
      :delta
      (fn [env]
        (let [hi (aget delta-range 1)]
          (loop [i (aget delta-range 0)]
            (when (< i hi)
              (visit env (rel/nth-row r i))
              (recur (inc i))))))

      :scan
      (fn [env]
        (let [hi (rel/visible-size r)]
          (loop [i 0]
            (when (< i hi)
              (visit env (rel/nth-row r i))
              (recur (inc i))))))

      :index
      (let [idx (rel/index r (long-array (:key-pos step)))
            build-key (key-builder (:key step) boxed)]
        (fn [env]
          (when-let [^ArrayList b (rel/lookup r idx (build-key env))]
            (let [n (.size b)]
              (loop [i 0]
                (when (< i n)
                  (visit env (.get b i))
                  (recur (inc i)))))))))))

(defn compile-variant
  "Compiles one variant of the lowered `rule`.

  `relations` maps predicate ids to relations, `boxed` is the array of boxed
  rank `Long`s, and `delta` the index of the delta atom among the rule's
  positive atoms, or nil for the variant that reads everything.

  Returns a function of two longs `(lo hi)`: it runs the rule once, reading
  the delta atom from rows `[lo, hi)` of its relation (ignored without a
  delta atom), and returns nil."
  [rule relations boxed delta]
  (let [{:keys [pre steps]} (plan-steps rule delta)
        delta-range (long-array 2)
        head-rel (relations (get-in rule [:head :pid]))
        build-head (tuple-builder (get-in rule [:head :args]) boxed)
        emit (fn [env] (rel/add! head-rel (build-head env)))
        chain (reduce (fn [next step] (compile-step step relations boxed delta-range next))
                      emit (reverse steps))
        pre-test (all-of (mapv #(compile-filter % relations boxed) pre))
        start (if pre-test (fn [env] (when (pre-test env) (chain env))) chain)
        nslots (:nslots rule)]
    (fn [^long lo ^long hi]
      (aset delta-range 0 lo)
      (aset delta-range 1 hi)
      (start (long-array nslots))
      nil)))
