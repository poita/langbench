(ns sqlitefile.schema
  "The catalog: `sqlite_schema` read once, with every `CREATE TABLE` and
  `CREATE INDEX` parsed (SPEC §1.10 and Part 2)."
  (:require [clojure.string :as str]
            [sqlitefile.btree :as btree]
            [sqlitefile.ddl :as ddl]
            [sqlitefile.record :as record]))

(set! *warn-on-reflection* true)

(defn ascii-lower
  "Lower-case the ASCII letters of `s`, leaving every other character alone."
  [^String s]
  (let [sb (StringBuilder. (.length s))]
    (dotimes [i (.length s)]
      (let [c (.charAt s i)]
        (.append sb (if (<= 65 (int c) 90) (char (+ (int c) 32)) c))))
    (str sb)))

(defn- entry [rowid [type name tbl-name root sql]]
  {:rowid rowid :type type :name name :tbl-name tbl-name
   :root (when (integer? root) root) :sql sql})

(defn- try-parse [f sql]
  (when (string? sql)
    (try (f sql) (catch Exception _ nil))))

(defn- add-object [catalog {:keys [type name root sql] :as e}]
  (let [k (ascii-lower (str name))]
    (case type
      "table" (update catalog :tables
                      (fn [m]
                        (if (contains? m k)
                          m
                          (assoc m k (merge {:name name :root root :sql sql}
                                            (try-parse ddl/parse-create-table sql))))))
      "index" (update catalog :indexes
                      (fn [m]
                        (if (contains? m k)
                          m
                          (assoc m k (merge {:name name :root root :sql sql :tbl-name (:tbl-name e)}
                                            (try-parse ddl/parse-create-index sql))))))
      catalog)))

(defn load-catalog
  "Read `sqlite_schema` (rooted at page 1) from `db` and return
  `{:entries [row ...] :tables {lower-name table} :indexes {lower-name index}}`.
  `:entries` keeps every schema row in rowid order; each is
  `{:rowid :type :name :tbl-name :root :sql}`."
  [db]
  (let [entries (persistent!
                 (btree/table-reduce
                  db 1
                  (fn [acc rowid payload] (conj! acc (entry rowid (record/decode payload))))
                  (transient [])))]
    (reduce add-object {:entries entries :tables {} :indexes {}} entries)))

(defn find-table
  "The table named `name` (ASCII case-insensitive), or nil. Includes
  `sqlite_sequence` but not `sqlite_schema` itself."
  [catalog name]
  (get-in catalog [:tables (ascii-lower name)]))

(defn find-index
  "The index named `name` (ASCII case-insensitive), or nil."
  [catalog name]
  (get-in catalog [:indexes (ascii-lower name)]))

(defn column-ref
  "Resolve a column name of `table` to its position, `:rowid` for the rowid
  pseudo-column, or nil. A real column named `rowid` wins over the pseudo
  column."
  [table name]
  (let [lname (ascii-lower name)]
    (or (first (keep-indexed (fn [i c] (when (= lname (ascii-lower (:name c))) i))
                             (:columns table)))
        (when (= lname "rowid") :rowid))))

(defn column-affinity
  "Affinity of a resolved column reference: `:integer` for the rowid and the
  rowid alias."
  [table ref]
  (if (or (= ref :rowid) (= ref (:rowid-alias table)))
    :integer
    (:affinity (nth (:columns table) ref))))
