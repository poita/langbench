(ns sqlitefile.exec
  "Executing parsed queries (see [[sqlitefile.query]]) against a database and
  its catalog. Every function returns plain data; formatting to text is done
  by [[run]]."
  (:require [clojure.string :as str]
            [sqlitefile.btree :as btree]
            [sqlitefile.record :as record]
            [sqlitefile.schema :as schema]
            [sqlitefile.value :as value]))

(set! *warn-on-reflection* true)

(defn- query-error [msg data]
  (throw (ex-info msg (assoc data :type :sqlitefile/query))))

(defn- require-table [catalog name]
  (let [t (or (schema/find-table catalog name)
              (query-error "no such table" {:table name}))]
    (when-not (:columns t) (query-error "unreadable table definition" {:table name}))
    (when-not (:root t) (query-error "table has no root page" {:table name}))
    t))

(defn row-values
  "The column values of a table row as a vector with one entry per declared
  column: missing trailing columns are NULL, the rowid alias is replaced by
  the rowid, and integers in REAL-affinity columns become doubles."
  [table rowid record]
  (let [cols (:columns table)
        alias (:rowid-alias table)
        n (count record)]
    (loop [i 0 out (transient [])]
      (if (< i (count cols))
        (let [v (if (< i n) (nth record i) nil)
              v (cond
                  (= i alias) rowid
                  (and (instance? Long v) (= :real (:affinity (nth cols i)))) (double v)
                  :else v)]
          (recur (inc i) (conj! out v)))
        (persistent! out)))))

(defn tables
  "Sorted names of the user tables (those not starting with `sqlite_`)."
  [catalog]
  (->> (:entries catalog)
       (filter #(and (= "table" (:type %))
                     (string? (:name %))
                     (not (str/starts-with? (schema/ascii-lower (:name %)) "sqlite_"))))
       (map :name)
       (sort value/compare-values)
       vec))

(defn schema-sql
  "The `CREATE` statements (without trailing `;`) of every schema row whose
  `tbl_name` is `table`, in schema order."
  [catalog table]
  (let [t (schema/ascii-lower table)]
    (->> (:entries catalog)
         (filter #(and (string? (:tbl-name %))
                       (string? (:sql %))
                       (= t (schema/ascii-lower (:tbl-name %)))))
         (mapv :sql))))

(defn count-rows
  "Number of rows in `table-name`."
  [db catalog table-name]
  (btree/table-count db (:root (require-table catalog table-name))))

(defn- resolve-column [table name]
  (or (schema/column-ref table name)
      (query-error "no such column" {:column name})))

(defn- column-value [^long ref-idx rowid values]
  (if (neg? ref-idx) rowid (nth values ref-idx)))

(defn- ref->idx
  "Resolved column references are a column index or `-1` for the rowid."
  ^long [ref]
  (if (= ref :rowid) -1 (long ref)))

(defn- condition-fn [table {:keys [column op literal]}]
  (let [ref (resolve-column table column)
        idx (ref->idx ref)
        lit (value/apply-affinity (schema/column-affinity table ref) literal)
        test (case op
               :is (fn [v] (zero? (value/compare-values v lit)))
               :is-not (fn [v] (not (zero? (value/compare-values v lit))))
               (let [pred (case op
                            := zero? :!= (complement zero?)
                            :< neg? :<= (complement pos?)
                            :> pos? :>= (complement neg?))]
                 (fn [v] (and (some? v) (some? lit)
                              (pred (value/compare-values v lit))))))]
    (fn [rowid values] (test (column-value idx rowid values)))))

(defn select
  "Run a parsed `:select` command, returning a vector of rows, each a vector
  of values in select-list order."
  [db catalog {:keys [columns table where order limit]}]
  (let [t (require-table catalog table)
        refs (if (= columns :all)
               (vec (range (count (:columns t))))
               (mapv #(resolve-column t %) columns))
        idxs (mapv ref->idx refs)
        preds (mapv #(condition-fn t %) where)
        order-idx (some->> order :column (resolve-column t) ref->idx)
        desc? (:desc? order)
        matches? (fn [rowid values] (every? #(% rowid values) preds))
        project (fn [[rowid values]] (mapv #(column-value % rowid values) idxs))
        scan (fn [rf init]
               (btree/table-reduce
                db (:root t)
                (fn [acc rowid payload]
                  (let [values (row-values t rowid (record/decode payload))]
                    (if (matches? rowid values)
                      (rf acc [rowid values])
                      acc)))
                init))]
    (cond
      (and limit (zero? limit)) []

      order
      (let [rows (scan conj [])
            key-of (fn [[rowid values]] (column-value order-idx rowid values))
            cmp (if desc?
                  (fn [a b] (value/compare-values (key-of b) (key-of a)))
                  (fn [a b] (value/compare-values (key-of a) (key-of b))))
            ;; stable sort over rowid-ordered input keeps ties in ascending rowid
            sorted (sort cmp rows)]
        (mapv project (if limit (take limit sorted) sorted)))

      :else
      (mapv project
            (scan (fn [acc row]
                    (let [acc (conj acc row)]
                      (if (and limit (>= (count acc) limit)) (reduced acc) acc)))
                  [])))))

(defn index-lookup
  "Rows (as for `SELECT *`) of the table indexed by `index-name` whose indexed
  column equals `literal`, in ascending rowid order."
  [db catalog index-name literal]
  (let [idx (schema/find-index catalog index-name)]
    (when-not (and idx (string? (:sql idx)) (:root idx))
      (query-error "no such index" {:index index-name}))
    (when-not (= 1 (count (:columns idx)))
      (query-error "index must have exactly one column" {:index index-name}))
    (let [t (require-table catalog (:table idx))
          ref (resolve-column t (first (:columns idx)))
          key (value/apply-affinity (schema/column-affinity t ref) literal)]
      (if (nil? key)
        []
        (let [rowids (->> (btree/index-find db (:root idx) key)
                          (map peek)
                          sort)]
          (vec (for [rowid rowids
                     :let [payload (btree/table-find db (:root t) rowid)]
                     :when payload]
                 (row-values t rowid (record/decode payload)))))))))

(defn- lines->text [lines]
  (let [sb (StringBuilder.)]
    (doseq [l lines] (.append sb ^String l) (.append sb \newline))
    (str sb)))

(defn- rows->text [rows]
  (lines->text (map #(str/join "\t" (map value/format-value %)) rows)))

(defn run
  "Execute the parsed command `cmd` and return its output text (each line
  terminated by a newline; empty when there are no rows)."
  [db catalog cmd]
  (case (:op cmd)
    :tables (lines->text (tables catalog))
    :schema (lines->text (map #(str % ";") (schema-sql catalog (:table cmd))))
    :count (lines->text [(str (count-rows db catalog (:table cmd)))])
    :select (rows->text (select db catalog cmd))
    :index (rows->text (index-lookup db catalog (:index cmd) (:literal cmd)))))
