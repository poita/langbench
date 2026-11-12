(ns kvstore.index
  "Secondary indexes (spec section 14): key encoding, maintenance on writes,
  creation, dropping and candidate range scans for `find`."
  (:require [clojure.string :as str]
            [kvstore.btree :as bt]
            [kvstore.bytes :as b]
            [kvstore.header :as h]
            [kvstore.limits :as lim]
            [kvstore.txn :as txn]
            [kvstore.value :as v])
  (:import (java.io ByteArrayOutputStream)))

(set! *warn-on-reflection* true)

(defn- fail [kind]
  (throw (ex-info (name kind) {:kind kind})))

;; ---------------------------------------------------------------------------
;; Key encoding

(defn vkey
  "Order-preserving, self-delimiting encoding of a scalar value, or nil for a
  list or object (which are not indexable)."
  ^bytes [x]
  (cond
    (nil? x) (byte-array [0x10])
    (false? x) (byte-array [0x20])
    (true? x) (byte-array [0x21])
    (integer? x) (let [out (byte-array 9)]
                   (b/put-u8! out 0 0x30)
                   (b/put-u64! out 1 (bit-xor (long x) Long/MIN_VALUE))
                   out)
    (string? x) (let [out (ByteArrayOutputStream.)
                      ^bytes sb (b/utf8 x)]
                  (.write out 0x40)
                  (dotimes [i (alength sb)]
                    (let [c (aget sb i)]
                      (.write out (int c))
                      (when (zero? c) (.write out 0xFF))))
                  (.write out 0)
                  (.write out 0)
                  (.toByteArray out))
    :else nil))

(defn doc-key-of
  "The primary key at the end of an index key: everything after the vkey."
  ^bytes [^bytes entry]
  (let [tag (b/u8 entry 0)]
    (case (int tag)
      (0x10 0x20 0x21) (b/sub entry 1 (alength entry))
      0x30 (b/sub entry 9 (alength entry))
      0x40 (loop [i 1]
             (if (zero? (b/u8 entry i))
               (if (== 0xFF (b/u8 entry (inc i)))
                 (recur (+ i 2))
                 (b/sub entry (+ i 2) (alength entry)))
               (recur (inc i)))))))

(defn path-segments
  "Split a path text (`a.b.c`) into its segments."
  [^String path]
  (str/split path #"\."))

(defn entry-key
  "Index key of document `doc` (under primary key `k`) for the path
  `segments`, or nil when the path is missing or not a scalar."
  ^bytes [doc segments ^bytes k]
  (let [x (v/resolve-path doc segments)]
    (when-not (identical? x v/missing)
      (when-let [vk (vkey x)]
        (b/concat-bytes vk k)))))

(defn check-keys!
  "Throw `:index-key-too-long` when `doc` under `k` would produce an index key
  beyond 128 bytes in any live index."
  [pg ^bytes k doc]
  (doseq [{:keys [path]} (h/live-slots pg)]
    (when-let [^bytes ek (entry-key doc (path-segments path) k)]
      (when (> (alength ek) lim/max-index-key)
        (fail :index-key-too-long)))))

;; ---------------------------------------------------------------------------
;; Maintenance (spec 14.3)

(defn- adjust! [pg slot delta]
  (h/add-slot-entries! pg slot delta))

(defn maintain!
  "Bring every live index in line after the document under `k` changed from
  `old` (nil-able, ignored when there is no old document) to `new`."
  [pg ^bytes k old new]
  (doseq [{:keys [slot path]} (h/live-slots pg)]
    (let [segs (path-segments path)
          o (when old (entry-key old segs k))
          w (entry-key new segs k)
          tree (bt/slot-tree slot)]
      (cond
        (and (nil? o) (nil? w)) nil
        (nil? o) (do (bt/insert! pg tree {:key w}) (adjust! pg slot 1))
        (nil? w) (do (bt/delete! pg tree o) (adjust! pg slot -1))
        (b/bytes= o w) nil
        :else (do (bt/delete! pg tree o) (bt/insert! pg tree {:key w}))))))

(defn remove-entries!
  "Delete the entries of the removed document `old` (spec 14.3, `delete`)."
  [pg ^bytes k old]
  (doseq [{:keys [slot path]} (h/live-slots pg)]
    (when-let [o (entry-key old (path-segments path) k)]
      (bt/delete! pg (bt/slot-tree slot) o)
      (adjust! pg slot -1))))

;; ---------------------------------------------------------------------------
;; create / drop

(defn create!
  "Build an index on `path` (a vector of segments).  Returns the entry count."
  [pg segments primary-tree read-doc]
  (let [text (str/join "." segments)]
    (when (h/find-slot pg text) (fail :index-exists))
    (when (>= (long (h/get-field pg :index-count)) lim/max-indexes) (fail :index-limit))
    (let [entries (into []
                        (keep (fn [cell]
                                (when-let [ek (entry-key (read-doc cell) segments (:key cell))]
                                  (when (> (alength ^bytes ek) lim/max-index-key)
                                    (fail :index-key-too-long))
                                  ek)))
                        (bt/cells-from pg primary-tree nil))]
      (txn/run-write
       pg
       (fn [pg]
         (let [slot (h/first-free-slot pg)
               tree (bt/slot-tree slot)]
           (h/init-slot! pg slot text)
           (doseq [ek entries]
             (bt/insert! pg tree {:key ek})
             (adjust! pg slot 1))
           (count entries)))))))

(defn drop!
  "Drop the index on `path` text.  Returns the number of pages freed."
  [pg ^String text]
  (let [{:keys [slot]} (or (h/find-slot pg text) (fail :index-missing))]
    (txn/run-write
     pg
     (fn [pg]
       (let [n (bt/free-tree! pg (bt/slot-tree slot))]
         (h/clear-slot! pg slot)
         n)))))

;; ---------------------------------------------------------------------------
;; Candidate scans (spec 17.3)

(defn candidates
  "Lazy sequence of index keys that are candidates for the comparison
  `(op value)` on the index in `slot`."
  [pg slot op value]
  (let [tree (bt/slot-tree slot)
        ^bytes vk (vkey value)
        below? (fn [^bytes e] (neg? (b/compare-bytes e vk)))
        pre? (fn [e] (b/prefix? vk e))
        keys-of (fn [from] (map :key (bt/cells-from pg tree from)))]
    (case op
      "==" (take-while pre? (keys-of vk))
      "<" (take-while below? (keys-of nil))
      "<=" (take-while #(or (below? %) (pre? %)) (keys-of nil))
      ">" (drop-while pre? (keys-of vk))
      ">=" (keys-of vk))))
