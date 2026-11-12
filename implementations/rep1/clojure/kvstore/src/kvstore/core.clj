(ns kvstore.core
  "Public API of the Tessera embedded document store.

  A database is held in memory as two byte arrays, the main file and the
  write-ahead log, exactly as they would sit on disk (`files` returns them).
  Documents are plain Clojure data: `nil`, booleans, `long`s, strings,
  vectors and maps with string keys.  Keys are non-empty strings of at most
  128 UTF-8 bytes.

  Failures are `ex-info` exceptions whose `ex-data` has a `:kind` keyword
  such as `:not-found`, `:bad-key`, `:doc-too-large`, `:index-exists`,
  `:txn-active` or `:no-txn`.

      (require '[kvstore.core :as kv])
      (def db (kv/open))
      (kv/put! db \"u1\" {\"name\" \"ada\" \"age\" 36})
      (kv/create-index! db \"age\")
      (kv/find db \"age > 30\")
      ;=> {:plan \"index age\", :rows [[\"u1\" {\"age\" 36, \"name\" \"ada\"}]]}"
  (:refer-clojure :exclude [find get])
  (:require [kvstore.bytes :as b]
            [kvstore.btree :as bt]
            [kvstore.docs :as docs]
            [kvstore.exec :as exec]
            [kvstore.header :as h]
            [kvstore.index :as ix]
            [kvstore.pager :as pager]
            [kvstore.parser :as parser]
            [kvstore.query :as query]
            [kvstore.recover :as recover]
            [kvstore.txn :as txn]
            [kvstore.value :as v]))

(set! *warn-on-reflection* true)

(defn open
  "Open a database.  With no arguments, a fresh empty one.  Otherwise a map
  with optional `:main` and `:wal` byte arrays (the contents of `main.tdb` and
  `main.twal`); the log is replayed and trimmed to its last committed
  transaction (crash recovery)."
  ([] (open {}))
  ([{:keys [main wal]}] (recover/open main wal)))

(defn files
  "The current database image as `{:main bytes :wal bytes}`: what
  `main.tdb` and `main.twal` would contain right now."
  [db]
  {:main (pager/main-file db)
   :wal (.toByteArray (pager/log db))})

(defn- key-bytes ^bytes [k]
  (docs/check-key! (b/utf8 k)))

(defn- segments [path]
  (let [segs (if (string? path) (ix/path-segments path) (vec path))]
    (when (or (> (count segs) 8) (> (count (clojure.string/join "." segs)) 30))
      (throw (ex-info "bad path" {:kind :bad-path})))
    segs))

;; --- documents -------------------------------------------------------------

(defn put!
  "Store `doc` under `k`.  Returns `:created` or `:replaced`."
  [db k doc]
  (docs/put! db (key-bytes k) doc))

(defn get
  "The document under `k`; throws `:not-found` when absent."
  [db k]
  (docs/get-doc db (key-bytes k)))

(defn delete!
  "Remove `k`; throws `:not-found` when absent."
  [db k]
  (docs/delete! db (key-bytes k))
  nil)

(defn update!
  "Set the field at `path` (a `\"a.b\"` string or a vector of segment names)
  of the document under `k` to `value`, creating intermediate objects."
  [db k path value]
  (docs/update! db (key-bytes k) (segments path) value)
  nil)

(defn unset!
  "Remove the field at `path` from the document under `k`."
  [db k path]
  (docs/unset! db (key-bytes k) (segments path))
  nil)

(defn scan
  "Entries in key order as a vector of `[key doc]` pairs (or of keys when
  `:keys?` is true).  Options: `:from` (inclusive), `:to` (exclusive),
  `:limit`, `:reverse?`."
  ([db] (scan db {}))
  ([db {:keys [from to limit reverse? keys?]}]
   (let [cells (docs/scan db {:from (some-> from b/utf8) :to (some-> to b/utf8)
                              :limit limit :reverse reverse?})]
     (if keys?
       (mapv #(b/from-utf8 (:key %)) cells)
       (mapv (fn [c] [(b/from-utf8 (:key c)) (docs/cell-doc db c)]) cells)))))

(defn find
  "Documents matching the predicate `pred-text` (the text that follows `find`
  in the command language, e.g. `\"age > 30 and name == \\\"ada\\\"\"`).
  Returns `{:plan \"scan\" | \"index <path>\", :rows [[key doc] ...]}` in key
  order.  `:limit` caps the number of rows."
  ([db pred-text] (find db pred-text {}))
  ([db pred-text {:keys [limit]}]
   (-> (query/find-docs db (parser/parse-predicate pred-text) limit)
       (update :rows (fn [rows] (mapv (fn [[k d]] [(b/from-utf8 k) d]) rows))))))

;; --- indexes ---------------------------------------------------------------

(defn create-index!
  "Build a secondary index on `path`.  Returns the number of entries."
  [db path]
  (ix/create! db (segments path) docs/primary #(docs/cell-doc db %)))

(defn drop-index!
  "Drop the index on `path`.  Returns the number of pages freed."
  [db path]
  (ix/drop! db (clojure.string/join "." (segments path))))

(defn indexes
  "Live indexes as maps `{:slot :path :root :entries}` in slot order."
  [db]
  (mapv #(select-keys % [:slot :path :root :entries]) (h/live-slots db)))

;; --- transactions ----------------------------------------------------------

(defn begin! "Open an explicit transaction." [db] (txn/begin! db) nil)

(defn commit!
  "Commit the open transaction.  Returns `{:txn-id n :frames n}`."
  [db]
  (txn/commit! db))

(defn rollback! "Discard the open transaction." [db] (txn/rollback! db) nil)

(defn checkpoint!
  "Copy the log into the main file.  Returns the number of pages copied."
  [db]
  (txn/checkpoint! db))

(defn stat
  "Store statistics: `:pages :free :freehead :docs :root :height :commits
  :indexes :wal`."
  [db]
  (docs/stats db))

;; --- command language ------------------------------------------------------

(defn execute!
  "Run one line of the command language.  Returns `{:status \"ok ...\" or
  \"error <kind>\", :lines [payload ...]}`."
  [db line]
  (let [[status lines] (exec/run-line db line)]
    {:status status :lines lines}))

(defn close!
  "Finish with `db`: roll back any open transaction and return its `files`."
  [db]
  (txn/end-of-script! db)
  (files db))
