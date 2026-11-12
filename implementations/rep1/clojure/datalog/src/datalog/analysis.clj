(ns datalog.analysis
  "Static checks on a program: safety and stratification.

  Both functions throw an `ex-info` on failure; the data's `:type` is
  `:datalog/unsafe-rule` or `:datalog/not-stratifiable`."
  (:require [datalog.syntax :as syn]))

;; ---------------------------------------------------------------------------
;; Safety

(defn- positive-vars
  "Named variables occurring in a positive body atom of the rule."
  [rule]
  (into #{}
        (comp (filter #(= :pos (:op %)))
              (mapcat #(:args (:atom %)))
              (filter symbol?)
              (remove syn/anonymous?))
        (:body rule)))

(defn unsafe-rule?
  "A rule is unsafe when a variable of its head, of a negated atom or of a
  comparison does not occur in a positive body atom. `_` never does, so it
  makes any of those places unsafe."
  [rule]
  (let [bound (positive-vars rule)
        bad? (fn [t] (and (syn/variable? t) (not (contains? bound t))))]
    (or (some bad? (:args (:head rule)))
        (some (fn [lit]
                (case (:op lit)
                  :pos false
                  :neg (some bad? (:args (:atom lit)))
                  :cmp (or (bad? (:left lit)) (bad? (:right lit)))))
              (:body rule)))))

(defn check-safety!
  "Throws if any rule (or fact) of `rules` is unsafe."
  [rules]
  (when-let [r (first (filter unsafe-rule? rules))]
    (throw (ex-info "unsafe rule" {:type :datalog/unsafe-rule :rule r}))))

;; ---------------------------------------------------------------------------
;; Dependency graph and stratification

(defn dependency-edges
  "Edges `[head-key body-key negative?]` of the dependency graph (oriented
  from a rule's head to the predicates it depends on)."
  [rules]
  (for [{:keys [head body]} rules
        lit body
        :when (#{:pos :neg} (:op lit))]
    [(syn/atom-key head) (syn/atom-key (:atom lit)) (= :neg (:op lit))]))

(defn- tarjan
  "Strongly connected components of the graph `succ` (key -> collection of
  keys) over `nodes`. Components come out so that every component appears
  after all components reachable from it, i.e. dependencies first."
  [nodes succ]
  (let [index (volatile! {}) low (volatile! {}) on-stack (volatile! #{})
        stack (volatile! []) counter (volatile! 0) out (volatile! [])]
    (letfn [(visit [v]
              (vswap! index assoc v @counter)
              (vswap! low assoc v @counter)
              (vswap! counter inc)
              (vswap! stack conj v)
              (vswap! on-stack conj v)
              (doseq [w (succ v)]
                (cond
                  (not (contains? @index w))
                  (do (visit w)
                      (vswap! low assoc v (min (@low v) (@low w))))
                  (contains? @on-stack w)
                  (vswap! low assoc v (min (@low v) (@index w)))))
              (when (= (@low v) (@index v))
                (loop [comp []]
                  (let [w (peek @stack)]
                    (vswap! stack pop)
                    (vswap! on-stack disj w)
                    (if (= w v)
                      (vswap! out conj (conj comp w))
                      (recur (conj comp w)))))))]
      (doseq [v nodes]
        (when-not (contains? @index v) (visit v))))
    @out))

(defn stratify
  "Computes the strongly connected components of the predicate dependency
  graph of `rules` and returns them as a vector of vectors of predicate
  keys, lowest stratum first (dependencies before dependents). Throws if a
  negative edge lies on a cycle, i.e. inside a component."
  [rules]
  (let [edges (dependency-edges rules)
        nodes (distinct (concat (map first edges) (map second edges)
                                (map (comp syn/atom-key :head) rules)))
        succ (reduce (fn [m [h b _]] (update m h (fnil conj []) b)) {} edges)
        comps (tarjan nodes #(get succ % []))
        comp-of (into {} (for [c comps k c] [k c]))]
    (when-let [[h b _] (first (filter (fn [[h b neg?]] (and neg? (= (comp-of h) (comp-of b))))
                                      edges))]
      (throw (ex-info "program is not stratifiable"
                      {:type :datalog/not-stratifiable :from h :through b})))
    (vec comps)))
