(ns minisql.binder
  "Binding: resolve column references against a scope and run the semantic
  checks, turning parser expressions into *bound* expressions.

  A **scope** is a vector with one entry per FROM table, in FROM order:
  `{:name effective-name :cols [lower-case column names]}`.

  In a bound expression every `[:col qual name]` has become `[:col t i]`:
  `t` is the table's position in the scope, `i` the column's position in that
  table's rows.  Everything else keeps the parser's shape."
  (:require [minisql.error :as err]))

(defn resolve-column
  "Resolve a column reference to `[t i]`.  Errors if the table or column is
  unknown, or if an unqualified name is ambiguous."
  [scope qual name]
  (if qual
    (let [t (first (keep-indexed (fn [i s] (when (= qual (:name s)) i)) scope))]
      (when-not t (err/semantic! (str "no such table: " qual)))
      (let [i (.indexOf ^java.util.List (:cols (nth scope t)) name)]
        (when (neg? i) (err/semantic! (str "no such column: " qual "." name)))
        [t i]))
    (let [hits (for [[t s] (map-indexed vector scope)
                     :let [i (.indexOf ^java.util.List (:cols s) name)]
                     :when (>= i 0)]
                 [t i])]
      (case (count hits)
        0 (err/semantic! (str "no such column: " name))
        1 (first hits)
        (err/semantic! (str "ambiguous column: " name))))))

(defn aggregate?
  "True if the (parsed or bound) expression `e` contains an aggregate call."
  [e]
  (boolean (some #(and (vector? %) (= :agg (first %))) (tree-seq vector? seq e))))

(defn bind-expr
  "Bind expression `e` in `scope`.  Aggregate calls are an error unless
  `aggregates?` is true; aggregates never nest."
  [scope e aggregates?]
  (letfn [(go [e in-agg?]
            (case (nth e 0)
              :lit e
              :col (let [[_ q n] e
                         [t i] (resolve-column scope q n)]
                     [:col t i])
              :agg (let [[_ f arg] e]
                     (cond
                       (not aggregates?) (err/semantic! "aggregate function not allowed here")
                       in-agg? (err/semantic! "nested aggregate function")
                       :else [:agg f (if (= arg :star) :star (go arg true))]))
              (into [(nth e 0)] (map #(go % in-agg?)) (rest e))))]
    (go e false)))

(defn columns-of
  "The set of `[t i]` column positions `e` reads outside aggregate calls."
  [e]
  (case (nth e 0)
    :lit #{}
    :col #{[(nth e 1) (nth e 2)]}
    :agg #{}
    (into #{} (mapcat columns-of) (rest e))))

(defn tables-of
  "The set of table positions that bound expression `e` reads (including
  inside aggregate arguments)."
  [e]
  (case (nth e 0)
    :lit #{}
    :col #{(nth e 1)}
    :agg (if (= :star (nth e 2)) #{} (tables-of (nth e 2)))
    (into #{} (mapcat tables-of) (rest e))))

(defn check-grouped!
  "Error unless every column `e` reads outside aggregate calls is in the set
  `group-cols` of `[t i]` grouping columns."
  [e group-cols]
  (doseq [c (columns-of e)]
    (when-not (contains? group-cols c)
      (err/semantic! "column must appear in GROUP BY or inside an aggregate"))))
