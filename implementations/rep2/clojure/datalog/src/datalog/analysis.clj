(ns datalog.analysis
  "Static checks on a parsed program: rule safety and stratification.

  A *predicate id* is the pair `[name arity]`: `r/1` and `r/2` are different
  predicates.")

(set! *warn-on-reflection* true)

(defn pred-id
  "The predicate id `[name arity]` of an atom (or atom-like map)."
  [{:keys [pred args]}]
  [pred (count args)])

(defn- variables
  "The set of variables (symbols) among `terms`."
  [terms]
  (into #{} (filter symbol?) terms))

(defn- literal-terms [lit]
  (case (:kind lit)
    :atom (:args lit)
    :cmp [(:left lit) (:right lit)]))

(defn safe-rule?
  "True when every variable of the head, of a negated atom and of a comparison
  also occurs in a positive body atom of `rule`."
  [{:keys [head body]}]
  (let [positive (into #{}
                       (comp (remove :negated?)
                             (filter #(= :atom (:kind %)))
                             (mapcat :args)
                             (filter symbol?))
                       body)
        needed (concat (variables (:args head))
                       (mapcat (fn [lit]
                                 (when-not (and (= :atom (:kind lit)) (not (:negated? lit)))
                                   (variables (literal-terms lit))))
                               body))]
    (every? positive needed)))

(defn unsafe-rules
  "The rules (and facts) of `clauses` that are not safe."
  [clauses]
  (into [] (comp (filter #(= :rule (:type %))) (remove safe-rule?)) clauses))

;; ---------------------------------------------------------------------------
;; Stratification

(defn dependency-graph
  "The predicate dependency graph of the rules in `clauses`.

  Returns `{:nodes #{pred-id}, :edges {head-id #{[body-id negative?] ...}}}`.
  Each edge goes from a head to a predicate it depends on, so a strongly
  connected component is evaluated after all components it points to.
  Predicates that occur only in queries are nodes too."
  [clauses]
  (reduce
   (fn [g clause]
     (case (:type clause)
       :query (update g :nodes conj (pred-id (:atom clause)))
       :rule
       (let [h (pred-id (:head clause))
             deps (for [lit (:body clause) :when (= :atom (:kind lit))]
                    [(pred-id lit) (boolean (:negated? lit))])]
         (-> g
             (update :nodes into (cons h (map first deps)))
             (update-in [:edges h] (fnil into #{}) deps)))))
   {:nodes #{} :edges {}}
   clauses))

(defn- tarjan
  "Strongly connected components of the graph, in dependency order: every
  component comes after all components it has edges to.  Each component is a
  vector of nodes."
  [nodes succ]
  (let [index (volatile! 0)
        indices (volatile! {})
        lowlink (volatile! {})
        stack (volatile! [])
        on-stack (volatile! #{})
        sccs (volatile! [])]
    (letfn [(visit [v]
              (vswap! indices assoc v @index)
              (vswap! lowlink assoc v @index)
              (vswap! index inc)
              (vswap! stack conj v)
              (vswap! on-stack conj v)
              (doseq [w (succ v)]
                (cond
                  (not (contains? @indices w))
                  (do (visit w)
                      (vswap! lowlink assoc v (min (@lowlink v) (@lowlink w))))
                  (contains? @on-stack w)
                  (vswap! lowlink assoc v (min (@lowlink v) (@indices w)))))
              (when (= (@lowlink v) (@indices v))
                (let [comp (loop [comp []]
                             (let [w (peek @stack)]
                               (vswap! stack pop)
                               (vswap! on-stack disj w)
                               (if (= w v) (conj comp w) (recur (conj comp w)))))]
                  (vswap! sccs conj comp))))]
      (doseq [v (sort nodes)]
        (when-not (contains? @indices v) (visit v))))
    @sccs))

(defn stratify
  "Splits the predicates of `clauses` into strata.

  Returns a vector of components (each a vector of predicate ids) in
  evaluation order, or `nil` when the program is not stratifiable, i.e. some
  cycle of the dependency graph contains a negative edge."
  [clauses]
  (let [{:keys [nodes edges]} (dependency-graph clauses)
        sccs (tarjan nodes #(map first (get edges %)))
        comp-of (into {} (for [[i comp] (map-indexed vector sccs), p comp] [p i]))
        bad? (some (fn [[h deps]]
                     (some (fn [[q neg?]] (and neg? (= (comp-of h) (comp-of q)))) deps))
                   edges)]
    (when-not bad? sccs)))
