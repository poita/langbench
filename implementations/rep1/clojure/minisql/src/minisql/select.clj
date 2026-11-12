(ns minisql.select
  "SELECT: binding a parsed query against the database into a plan, and
  executing the plan.

  Execution follows SPEC.md: candidate rows (scan, or hash join for two
  tables with a cross-table equality), WHERE/ON filtering, grouping, HAVING,
  select list, one stable ORDER BY sort, LIMIT/OFFSET."
  (:require [minisql.binder :as b]
            [minisql.error :as err]
            [minisql.eval :as ev]
            [minisql.value :as v])
  (:import (java.util ArrayList HashMap LinkedHashMap)))

;; ------------------------------------------------------------------- binding

(defn- lookup-table [db name]
  (or (get-in db [:tables name])
      (err/semantic! (str "no such table: " name))))

(defn- bind-from [db refs]
  (let [tables (mapv (fn [{:keys [table alias]}]
                       (assoc (lookup-table db table)
                              :effective (or alias table)))
                     refs)
        names (map :effective tables)]
    (when-not (= (count names) (count (set names)))
      (err/semantic! "duplicate table name in FROM"))
    tables))

(defn- expand-items
  "Parsed select items -> vector of `{:expr bound :alias a}`; `*` becomes one
  item per column."
  [scope items]
  (into []
        (mapcat (fn [{:keys [star expr alias]}]
                  (if star
                    (do (when (empty? scope) (err/semantic! "no tables specified"))
                        (for [[t s] (map-indexed vector scope)
                              i (range (count (:cols s)))]
                          {:expr [:col t i] :alias nil}))
                    [{:expr (b/bind-expr scope expr true) :alias alias}])))
        items))

(defn- bind-order-term
  "An ORDER BY term is an output-column reference (alias or ordinal) or an
  expression over the row/group."
  [scope items {:keys [expr name ordinal desc]}]
  (let [alias-idx (when name
                    (first (keep-indexed (fn [i it] (when (= name (:alias it)) i)) items)))]
    (cond
      alias-idx {:out alias-idx :desc desc}
      ordinal (do (when-not (<= 1 ordinal (count items))
                    (err/semantic! "ORDER BY ordinal out of range"))
                  {:out (dec ordinal) :desc desc})
      :else {:expr (b/bind-expr scope expr true) :desc desc})))

(defn bind-select
  "Bind parsed SELECT `q` against `db`, returning an execution plan."
  [db q]
  (let [tables (bind-from db (:tables q))
        scope (mapv (fn [t] {:name (:effective t) :cols (:cols t)}) tables)
        items (expand-items scope (:items q))
        where (when-let [w (:where q)] (b/bind-expr scope w false))
        group-cols (mapv (fn [[_ qual name]] (b/resolve-column scope qual name))
                         (:group-by q))
        having (when-let [h (:having q)] (b/bind-expr scope h true))
        order (mapv #(bind-order-term scope items %) (:order-by q))
        aggregate? (or (seq group-cols)
                       (boolean (some (fn [e] (b/aggregate? e))
                                      (concat (map :expr items)
                                              (when having [having])
                                              (keep :expr order)))))]
    (when aggregate?
      (let [gset (set group-cols)]
        (doseq [e (concat (map :expr items) (when having [having]) (keep :expr order))]
          (b/check-grouped! e gset))))
    {:tables (mapv :rows tables)
     :where where
     :group-cols group-cols
     :aggregate? (boolean aggregate?)
     :having having
     :items (mapv :expr items)
     :order order
     :limit (:limit q)
     :offset (:offset q)}))

;; ----------------------------------------------------------------- execution

(defn- conjuncts
  "Flatten nested ANDs into a vector of conjuncts."
  [e]
  (if (= :and (nth e 0))
    (into (conjuncts (nth e 1)) (conjuncts (nth e 2)))
    [e]))

(defn- pass?
  "True if every predicate is true in `env`."
  [preds env]
  (every? #(ev/true-value? (ev/evaluate % env nil)) preds))

(defn- join-key
  "Composite hash-join key of `exprs` in `env`, or nil if any part is NULL
  (NULL never equals anything)."
  [exprs env]
  (let [k (mapv #(ev/evaluate % env nil) exprs)]
    (when-not (some nil? k) k)))

(defn- equi-pair
  "If conjunct `c` is `l = r` with `l` reading only table 0 and `r` only
  table 1 (or vice versa), return `[expr-on-0 expr-on-1]`."
  [c]
  (when (= :eq (nth c 0))
    (let [l (nth c 1) r (nth c 2)
          tl (b/tables-of l) tr (b/tables-of r)]
      (cond (and (= tl #{0}) (= tr #{1})) [l r]
            (and (= tl #{1}) (= tr #{0})) [r l]))))

(defn- hash-join
  "Pairs of `arows` x `brows` whose join keys match, in nested-loop order,
  that also satisfy `residual`.  Expected O(A + B + M)."
  [arows brows keys residual]
  (let [akeys (mapv first keys)
        bkeys (mapv second keys)
        index (HashMap.)]
    (doseq [row brows]
      (when-let [k (join-key bkeys [nil row])]
        (let [^ArrayList bucket (or (.get index k)
                                    (let [l (ArrayList.)] (.put index k l) l))]
          (.add bucket row))))
    (persistent!
     (reduce (fn [out arow]
               (if-let [k (join-key akeys [arow nil])]
                 (if-let [^ArrayList bucket (.get index k)]
                   (reduce (fn [out brow]
                             (let [env [arow brow]]
                               (if (pass? residual env) (conj! out env) out)))
                           out bucket)
                   out)
                 out))
             (transient [])
             arows))))

(defn- nested-loop-join [arows brows preds]
  (persistent!
   (reduce (fn [out arow]
             (reduce (fn [out brow]
                       (let [env [arow brow]]
                         (if (pass? preds env) (conj! out env) out)))
                     out brows))
           (transient [])
           arows)))

(defn- candidates
  "The environments surviving WHERE/ON, in nested-loop order."
  [{:keys [tables where]}]
  (let [preds (if where (conjuncts where) [])]
    (case (count tables)
      0 (if (pass? preds []) [[]] [])
      1 (into [] (comp (map vector) (filter #(pass? preds %))) (first tables))
      2 (let [by-tables (group-by b/tables-of preds)
              consts (get by-tables #{})
              only-a (get by-tables #{0})
              only-b (get by-tables #{1})
              cross (get by-tables #{0 1})
              keys (vec (keep equi-pair cross))
              residual (vec (remove equi-pair cross))]
          (if-not (pass? consts [nil nil])
            []
            (let [arows (filterv #(pass? only-a [% nil]) (first tables))
                  brows (filterv #(pass? only-b [nil %]) (second tables))]
              (if (seq keys)
                (hash-join arows brows keys residual)
                (nested-loop-join arows brows cross))))))))

(defn- group-envs
  "Partition `envs` into groups.  Returns a vector of `[rep-env envs]`, where
  `rep-env` is the first env of the group (nil for the one empty group of an
  ungrouped aggregate query), ordered by ascending grouping values."
  [{:keys [group-cols]} envs]
  (if (empty? group-cols)
    [[(first envs) envs]]
    (let [m (LinkedHashMap.)]
      (doseq [env envs]
        (let [k (mapv (fn [[t i]] (nth (nth env t) i)) group-cols)
              ^ArrayList l (or (.get m k) (let [l (ArrayList.)] (.put m k l) l))]
          (.add l env)))
      (->> (seq m)
           (sort (fn [a b] (v/compare-rows (key a) (key b))))
           (mapv (fn [e] (let [envs (vec (val e))] [(first envs) envs])))))))

(defn- order-comparator [order]
  (let [n (count order)
        descs (mapv :desc order)]
    (fn [[_ ka] [_ kb]]
      (loop [i 0]
        (if (< i n)
          (let [c (v/compare-values (nth ka i) (nth kb i))
                c (if (nth descs i) (- c) c)]
            (if (zero? c) (recur (inc i)) c))
          0)))))

(defn execute-select
  "Run a plan produced by [[bind-select]]; returns a vector of output rows."
  [{:keys [items having order limit offset aggregate?] :as plan}]
  (let [envs (candidates plan)
        ;; each unit is [env group]; group is nil for non-aggregate queries
        units (if aggregate?
                (cond->> (group-envs plan envs)
                  having (filter (fn [[env g]] (ev/true-value? (ev/evaluate having env g)))))
                (map (fn [env] [env nil]) envs))
        rows (mapv (fn [[env g]]
                     (let [row (mapv #(ev/evaluate % env g) items)]
                       [row (when (seq order)
                              (mapv (fn [{:keys [out expr]}]
                                      (if (some? out)
                                        (nth row out)
                                        (ev/evaluate expr env g)))
                                    order))]))
                   units)
        sorted (if (seq order) (sort (order-comparator order) rows) rows)
        outs (map first sorted)
        outs (if offset (drop offset outs) outs)
        outs (if limit (take limit outs) outs)]
    (vec outs)))
