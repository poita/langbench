(ns sqlitefile.btree
  "Walking and searching table and index B-trees (SPEC §1.2–1.7)."
  (:require [sqlitefile.bytes :as b]
            [sqlitefile.pager :as pager]
            [sqlitefile.record :as record]
            [sqlitefile.value :as value])
  (:import (sqlitefile.pager Db)))

(set! *warn-on-reflection* true)

(def ^:private interior-index 0x02)
(def ^:private interior-table 0x05)
(def ^:private leaf-index 0x0a)
(def ^:private leaf-table 0x0d)

(def ^:private max-depth 64)

(defn- fail [msg data]
  (throw (ex-info msg (assoc data :type :sqlitefile/corrupt))))

;; A "page view" is just three longs worth of context; we compute them on
;; demand to avoid allocating objects in the hot loops.

(defn- page-base
  "Offset of the B-tree page header for page `pgno`."
  ^long [^Db db ^long pgno]
  (+ (pager/page-start db pgno) (if (= pgno 1) 100 0)))

(defn- cell-count ^long [^bytes data ^long base]
  (b/u16 data (+ base 3)))

(defn- cell-offset
  "Absolute offset of cell `i`, given the page's `start` offset and the offset
  `ptrs` of its cell pointer array."
  ^long [^bytes data ^long start ^long ptrs ^long i]
  (+ start (b/u16 data (+ ptrs (* 2 i)))))

(defn- right-child ^long [^bytes data ^long base]
  (b/u32 data (+ base 8)))

(defn- check-depth [^long depth]
  (when (> depth max-depth) (fail "b-tree too deep (cycle?)" {})))

;; ---------------------------------------------------------------------------
;; Table b-trees

(defn table-reduce
  "Reduce `(f acc rowid payload)` over every row of the table b-tree rooted at
  page `root`, in ascending rowid order. `payload` is the row's record bytes.
  `f` may return a `reduced` value to stop early."
  [^Db db ^long root f init]
  (let [^bytes data (.data db)]
    (letfn [(walk [acc ^long pgno ^long depth]
              (check-depth depth)
              (let [start (pager/page-start db pgno)
                    base (page-base db pgno)
                    type (b/u8 data base)
                    n (cell-count data base)]
                (cond
                  (= type leaf-table)
                  (loop [i 0 acc acc]
                    (if (< i n)
                      (let [pos (cell-offset data start (+ base 8) i)
                            size (b/varint data pos)
                            p2 (+ pos (b/varint-size data pos))
                            rowid (b/varint data p2)
                            p3 (+ p2 (b/varint-size data p2))
                            acc (f acc rowid (pager/read-payload db p3 size true))]
                        (if (reduced? acc) acc (recur (inc i) acc)))
                      acc))

                  (= type interior-table)
                  (loop [i 0 acc acc]
                    (if (< i n)
                      (let [child (b/u32 data (cell-offset data start (+ base 12) i))
                            acc (walk acc child (inc depth))]
                        (if (reduced? acc) acc (recur (inc i) acc)))
                      (walk acc (right-child data base) (inc depth))))

                  :else (fail "not a table b-tree page" {:page pgno :type type}))))]
      (unreduced (walk init root 0)))))

(defn table-count
  "Number of rows in the table b-tree at `root`, computed from the cell counts
  of the leaf pages without decoding any record."
  [^Db db ^long root]
  (let [^bytes data (.data db)]
    (letfn [(walk ^long [^long pgno ^long depth]
              (check-depth depth)
              (let [start (pager/page-start db pgno)
                    base (page-base db pgno)
                    type (b/u8 data base)
                    n (cell-count data base)]
                (cond
                  (= type leaf-table) n
                  (= type interior-table)
                  (loop [i 0 total 0]
                    (if (< i n)
                      (recur (inc i)
                             (+ total (long (walk (b/u32 data (cell-offset data start (+ base 12) i))
                                                 (inc depth)))))
                      (+ total (long (walk (right-child data base) (inc depth))))))
                  :else (fail "not a table b-tree page" {:page pgno :type type}))))]
      (walk root 0))))

(defn table-find
  "Return the record bytes of the row with `rowid` in the table b-tree at
  `root`, or nil when there is no such row."
  [^Db db ^long root ^long rowid]
  (let [^bytes data (.data db)]
    (loop [pgno root depth 0]
      (check-depth depth)
      (let [start (pager/page-start db pgno)
            base (page-base db pgno)
            type (b/u8 data base)
            n (cell-count data base)]
        (cond
          (= type leaf-table)
          (loop [lo 0 hi (dec n)]
            (when (<= lo hi)
              (let [mid (quot (+ lo hi) 2)
                    pos (cell-offset data start (+ base 8) mid)
                    p2 (+ pos (b/varint-size data pos))
                    k (b/varint data p2)]
                (cond
                  (= k rowid) (pager/read-payload db (+ p2 (b/varint-size data p2))
                                                  (b/varint data pos) true)
                  (< k rowid) (recur (inc mid) hi)
                  :else (recur lo (dec mid))))))

          (= type interior-table)
          ;; first cell whose key >= rowid, else the right-most child
          (let [idx (loop [lo 0 hi n]
                      (if (< lo hi)
                        (let [mid (quot (+ lo hi) 2)
                              pos (cell-offset data start (+ base 12) mid)
                              k (b/varint data (+ pos 4))]
                          (if (< k rowid) (recur (inc mid) hi) (recur lo mid)))
                        lo))]
            (recur (if (< idx n)
                     (b/u32 data (cell-offset data start (+ base 12) idx))
                     (right-child data base))
                   (inc depth)))

          :else (fail "not a table b-tree page" {:page pgno :type type}))))))

;; ---------------------------------------------------------------------------
;; Index b-trees

(defn- index-entry
  "Decode the entry of cell `i` of an index page."
  [^Db db ^bytes data start base interior? i]
  (let [pos (cell-offset data start (+ base (if interior? 12 8)) i)
        pos (if interior? (+ pos 4) pos)]
    (record/decode (pager/read-payload db (+ pos (b/varint-size data pos))
                                       (b/varint data pos) false))))

(defn index-find
  "Return, in index order, every entry (a decoded record: the indexed column
  values followed by the rowid) of the index b-tree at `root` whose first
  column equals `key`. Only the part of the tree that can contain `key` is
  visited."
  [^Db db ^long root key]
  (let [^bytes data (.data db)
        found (java.util.ArrayList.)]
    (letfn [(first-ge ^long [start base interior? ^long n]
              ;; first cell index whose first column is >= key
              (loop [lo 0 hi n]
                (if (< lo hi)
                  (let [mid (quot (+ lo hi) 2)
                        e (index-entry db data start base interior? mid)]
                    (if (neg? (value/compare-values (first e) key))
                      (recur (inc mid) hi)
                      (recur lo mid)))
                  lo)))
            ;; returns true once an entry greater than key was seen
            (walk [^long pgno ^long depth]
              (check-depth depth)
              (let [start (pager/page-start db pgno)
                    base (page-base db pgno)
                    type (b/u8 data base)
                    n (cell-count data base)]
                (cond
                  (= type leaf-index)
                  (loop [i (first-ge start base false n)]
                    (if (< i n)
                      (let [e (index-entry db data start base false i)
                            c (value/compare-values (first e) key)]
                        (cond (zero? c) (do (.add found e) (recur (inc i)))
                              :else true))
                      false))

                  (= type interior-index)
                  (loop [i (first-ge start base true n)]
                    (if (< i n)
                      (if (walk (b/u32 data (cell-offset data start (+ base 12) i)) (inc depth))
                        true
                        (let [e (index-entry db data start base true i)
                              c (value/compare-values (first e) key)]
                          (if (zero? c)
                            (do (.add found e) (recur (inc i)))
                            true)))
                      (walk (right-child data base) (inc depth))))

                  :else (fail "not an index b-tree page" {:page pgno :type type}))))]
      (walk root 0)
      (vec found))))
