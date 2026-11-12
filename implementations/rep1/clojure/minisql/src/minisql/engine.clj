(ns minisql.engine
  "Executes one parsed statement against a database value.

  A database is `{:tables {name {:name name :cols [name ...] :rows [[v ...] ...]}}}`
  with lower-case names and rows in insertion order.  [[execute]] is pure: it
  returns the new database and a result, and throws (see `minisql.error`)
  before changing anything when the statement is invalid."
  (:require [minisql.binder :as b]
            [minisql.error :as err]
            [minisql.eval :as ev]
            [minisql.select :as select]))

(def empty-db
  "A database with no tables."
  {:tables {}})

(defn- table-of [db name]
  (or (get-in db [:tables name])
      (err/semantic! (str "no such table: " name))))

(defn- single-scope [table]
  [{:name (:name table) :cols (:cols table)}])

(defn- create-table [db {:keys [table columns]}]
  (when (contains? (:tables db) table)
    (err/semantic! (str "table already exists: " table)))
  (let [cols (mapv first columns)]
    (when-not (= (count cols) (count (set cols)))
      (err/semantic! "duplicate column name"))
    [(assoc-in db [:tables table] {:name table :cols cols :rows []})
     {:type :ok}]))

(defn- insert-rows [db {:keys [table rows]}]
  (let [t (table-of db table)
        width (count (:cols t))
        bound (mapv (fn [row]
                      (when-not (= width (count row))
                        (err/semantic! "wrong number of values"))
                      (mapv #(b/bind-expr [] % false) row))
                    rows)
        new-rows (mapv (fn [row] (mapv #(ev/evaluate % [] nil) row)) bound)]
    [(update-in db [:tables table :rows] into new-rows)
     {:type :ok}]))

(defn- delete-rows [db {:keys [table where]}]
  (let [t (table-of db table)
        pred (when where (b/bind-expr (single-scope t) where false))
        keep? (fn [row] (not (or (nil? pred) (ev/true-value? (ev/evaluate pred [row] nil)))))]
    [(assoc-in db [:tables table :rows] (filterv keep? (:rows t)))
     {:type :ok}]))

(defn- update-rows [db {:keys [table set where]}]
  (let [t (table-of db table)
        scope (single-scope t)
        pred (when where (b/bind-expr scope where false))
        assigns (mapv (fn [[col e]]
                        (let [i (.indexOf ^java.util.List (:cols t) col)]
                          (when (neg? i) (err/semantic! (str "no such column: " col)))
                          [i (b/bind-expr scope e false)]))
                      set)
        update-row (fn [row]
                     (let [env [row]]
                       (if (or (nil? pred) (ev/true-value? (ev/evaluate pred env nil)))
                         ;; every right-hand side sees the old row
                         (reduce (fn [r [i e]] (assoc r i (ev/evaluate e env nil)))
                                 row assigns)
                         row)))
        new-rows (mapv update-row (:rows t))]
    [(assoc-in db [:tables table :rows] new-rows)
     {:type :ok}]))

(defn- run-select [db q]
  [db {:type :rows :rows (select/execute-select (select/bind-select db q))}])

(defn execute
  "Execute parsed statement `stmt` (see `minisql.parser/parse-statement`)
  against `db`.  Returns `[new-db result]` where `result` is `{:type :ok}` or
  `{:type :rows :rows [[value ...] ...]}`."
  [db stmt]
  (case (:type stmt)
    :create (create-table db stmt)
    :insert (insert-rows db stmt)
    :delete (delete-rows db stmt)
    :update (update-rows db stmt)
    :select (run-select db stmt)))
