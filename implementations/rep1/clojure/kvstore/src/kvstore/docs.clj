(ns kvstore.docs
  "Documents on the primary tree: validation, overflow handling and index
  maintenance for `put`, `get`, `delete`, `update`, `unset` and `scan`
  (spec sections 14.3 and 18.3).  Every function validates before it writes,
  so a failure changes nothing."
  (:require [kvstore.btree :as bt]
            [kvstore.bytes :as b]
            [kvstore.header :as h]
            [kvstore.index :as ix]
            [kvstore.limits :as lim]
            [kvstore.overflow :as ovf]
            [kvstore.pager :as pager]
            [kvstore.txn :as txn]
            [kvstore.value :as v]))

(set! *warn-on-reflection* true)

(def primary (bt/primary-tree))

(defn check-key!
  "Validate a key (non-empty, at most 128 bytes); returns it."
  ^bytes [^bytes k]
  (when (or (zero? (alength k)) (> (alength k) lim/max-key))
    (throw (ex-info "bad key" {:kind :bad-key})))
  k)

(defn- fail [kind]
  (throw (ex-info (name kind) {:kind kind})))

(defn- find-cell [pg ^bytes k]
  (bt/search pg primary k))

(defn cell-doc-bytes
  "The serialised document of a primary leaf cell, following its overflow chain."
  ^bytes [pg cell]
  (let [^bytes inline (:inline cell)
        ov (long (:overflow cell))]
    (if (zero? ov)
      inline
      (b/concat-bytes inline (ovf/read-chain pg ov (- (long (:doc-len cell)) (alength inline)))))))

(defn cell-doc
  "The deserialised document of a primary leaf cell."
  [pg cell]
  (v/deser (cell-doc-bytes pg cell)))

(defn get-doc
  "Document stored under `k`; throws `:not-found`."
  [pg ^bytes k]
  (if-let [cell (find-cell pg k)]
    (cell-doc pg cell)
    (fail :not-found)))

(defn- build-cell!
  "Primary leaf cell for `k` and serialised `doc-bytes`, allocating the
  overflow chain (before any tree page is touched)."
  [pg ^bytes k ^bytes doc-bytes]
  (let [len (alength doc-bytes)
        inline-len (min len lim/max-inline)
        ov (if (> len lim/max-inline)
             (ovf/write-chain! pg (b/sub doc-bytes lim/max-inline len))
             0)]
    {:key k :doc-len len :inline (b/sub doc-bytes 0 inline-len) :overflow ov}))

(defn- store!
  "Steps 2-3 of spec 14.3 for a put/update/unset; returns true when the key
  was created."
  [pg ^bytes k doc-bytes old-cell old-doc new-doc]
  (when old-cell
    (ovf/free-chain! pg (:overflow old-cell)))
  (let [cell (build-cell! pg k doc-bytes)]
    (bt/insert! pg primary cell)
    (when-not old-cell (h/add-field! pg :primary-count 1))
    (ix/maintain! pg k old-doc new-doc)
    (nil? old-cell)))

(defn put!
  "Store `doc` under `k`.  Returns `:created` or `:replaced`."
  [pg ^bytes k doc]
  (check-key! k)
  (let [doc-bytes (v/check-document! doc)]
    (ix/check-keys! pg k doc)
    (txn/run-write
     pg
     (fn [pg]
       (let [old-cell (find-cell pg k)
             old-doc (when (and old-cell (seq (h/live-slots pg))) (cell-doc pg old-cell))]
         (if (store! pg k doc-bytes old-cell old-doc doc) :created :replaced))))))

(defn delete!
  "Remove `k` (`:not-found` when absent)."
  [pg ^bytes k]
  (check-key! k)
  (let [cell (or (find-cell pg k) (fail :not-found))]
    (txn/run-write
     pg
     (fn [pg]
       (let [old-doc (when (seq (h/live-slots pg)) (cell-doc pg cell))]
         (ovf/free-chain! pg (:overflow cell))
         (bt/delete! pg primary k)
         (h/add-field! pg :primary-count -1)
         (ix/remove-entries! pg k old-doc)
         :removed)))))

(defn update!
  "Set the field at `segments` of the document under `k` to `value`."
  [pg ^bytes k segments value]
  (check-key! k)
  (let [cell (or (find-cell pg k) (fail :not-found))
        old-doc (cell-doc pg cell)
        new-doc (v/assoc-path old-doc segments value)
        doc-bytes (v/check-document! new-doc)]
    (ix/check-keys! pg k new-doc)
    (txn/run-write pg (fn [pg] (store! pg k doc-bytes cell old-doc new-doc) :updated))))

(defn unset!
  "Remove the field at `segments` from the document under `k`."
  [pg ^bytes k segments]
  (check-key! k)
  (let [cell (or (find-cell pg k) (fail :not-found))
        old-doc (cell-doc pg cell)
        new-doc (v/dissoc-path old-doc segments)
        doc-bytes (v/ser new-doc)]
    (txn/run-write pg (fn [pg] (store! pg k doc-bytes cell old-doc new-doc) :updated))))

(defn scan
  "Cells selected by a scan: keys `from <= k < to` (bounds are byte arrays or
  nil), optionally `reverse`d, at most `limit` of them.  Returns a vector of
  primary leaf cells; documents are not read."
  [pg {:keys [from to limit reverse]}]
  (let [lt-to? (fn [cell] (or (nil? to) (neg? (b/compare-bytes (:key cell) to))))
        ge-from? (fn [cell] (or (nil? from) (not (neg? (b/compare-bytes (:key cell) from)))))
        cells (if reverse
                (take-while ge-from? (bt/cells-below pg primary to))
                (take-while lt-to? (bt/cells-from pg primary from)))]
    (vec (if limit (take limit cells) cells))))

(defn stats
  "Header statistics as a map (spec 19.2 `stat`)."
  [pg]
  {:pages (h/get-field pg :page-count)
   :free (h/get-field pg :freelist-count)
   :freehead (h/get-field pg :freelist-head)
   :docs (h/get-field pg :primary-count)
   :root (h/get-field pg :primary-root)
   :height (bt/height pg primary)
   :commits (h/get-field pg :commit-counter)
   :indexes (h/get-field pg :index-count)
   :wal (pager/log-size pg)})
