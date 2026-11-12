(ns sqlitefile.core
  "Read-only access to SQLite 3 database files, implemented directly on the
  file format (no SQLite library involved).

      (require '[sqlitefile.core :as sf])

      (def db (sf/open \"people.sqlite\"))
      (sf/tables db)                         ;=> [\"people\"]
      (sf/select db \"people\" {:where [[\"age\" :> 40]] :order-by [\"name\" :desc]})
      (sf/query db \"SELECT name FROM people WHERE age > 40\")

  Values are plain Clojure data: `nil` (NULL), `Long` (INTEGER), `Double`
  (REAL), `String` (TEXT) and `byte[]` (BLOB).

  Failures throw `clojure.lang.ExceptionInfo` whose data has a `:type` of
  `:sqlitefile/corrupt` (bad file), `:sqlitefile/syntax` (unparseable query)
  or `:sqlitefile/query` (unknown table/column/index)."
  (:require [sqlitefile.exec :as exec]
            [sqlitefile.pager :as pager]
            [sqlitefile.query :as query]
            [sqlitefile.schema :as schema]
            [sqlitefile.value :as value]))

(defn- from-bytes* [pdb]
  {:pager pdb :catalog (schema/load-catalog pdb)})

(defn open
  "Load the database file at `path` (string, `File` or `Path`) and read its
  schema. Returns a database handle (a map) to pass to the other functions."
  [path]
  (from-bytes* (pager/open path)))

(defn from-bytes
  "Like [[open]], for the complete contents of a database file as a `byte[]`."
  [data]
  (from-bytes* (pager/from-bytes data)))

(defn tables
  "Sorted names of the user tables of `db` (excluding `sqlite_` tables)."
  [db]
  (exec/tables (:catalog db)))

(defn schema-sql
  "The `CREATE` statements (without trailing `;`) attached to `table`, in
  schema order: the table itself plus its indexes and triggers."
  [db table]
  (exec/schema-sql (:catalog db) table))

(defn columns
  "Column names of `table` in declared order, or nil when there is no such
  table."
  [db table]
  (some->> (schema/find-table (:catalog db) table) :columns (mapv :name)))

(defn count-rows
  "Number of rows in `table`, from the B-tree's leaf cell counts."
  [db table]
  (exec/count-rows (:pager db) (:catalog db) table))

(defn select
  "Rows of `table` as vectors of values.

  Options:
  * `:columns`  – vector of column names (default: all, in declared order;
                  `\"rowid\"` is allowed)
  * `:where`    – vector of `[column op literal]` conditions, all of which must
                  hold; `op` is one of `:=` `:!=` `:<` `:<=` `:>` `:>=` `:is`
                  `:is-not`
  * `:order-by` – `[column]` or `[column :desc]`; ties break by ascending rowid
  * `:limit`    – maximum number of rows

  Without `:order-by` rows come in ascending rowid order."
  ([db table] (select db table {}))
  ([db table {:keys [columns where order-by limit]}]
   (exec/select (:pager db) (:catalog db)
                (cond-> {:columns (or columns :all) :table table}
                  where (assoc :where (mapv (fn [[c op lit]] {:column c :op op :literal lit}) where))
                  order-by (assoc :order {:column (first order-by) :desc? (= :desc (second order-by))})
                  limit (assoc :limit limit)))))

(defn index-lookup
  "Rows (all columns, ascending rowid) of the table behind the single-column
  index `index-name` whose indexed value equals `literal`. The lookup walks
  the index B-tree, not the table."
  [db index-name literal]
  (exec/index-lookup (:pager db) (:catalog db) index-name literal))

(defn query
  "Run one line of the command language (`.tables`, `.schema T`, `COUNT T`,
  `SELECT ...`, `INDEX I literal`) and return its output text: one
  newline-terminated line per result row, or \"\" when there are none."
  [db line]
  (exec/run (:pager db) (:catalog db) (query/parse line)))

(defn format-value
  "Render a value as the command-line tool prints it."
  [v]
  (value/format-value v))
