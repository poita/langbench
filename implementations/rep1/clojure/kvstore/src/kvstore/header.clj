(ns kvstore.header
  "Page 1: the header fields and the index directory (spec sections 7.2 and 8).
  Header fields live in page 1 itself, so changing one dirties the page and a
  rollback restores them all."
  (:require [kvstore.bytes :as b]
            [kvstore.limits :as lim]
            [kvstore.pager :as pager]))

(set! *warn-on-reflection* true)

(def ^:private fields
  {:page-count [12 4]
   :freelist-head [16 4]
   :freelist-count [20 4]
   :primary-root [24 4]
   :primary-count [28 4]
   :commit-counter [32 8]
   :index-count [40 4]})

(defn get-field
  "Read a header field (`:page-count`, `:freelist-head`, `:freelist-count`,
  `:primary-root`, `:primary-count`, `:commit-counter`, `:index-count`)."
  ^long [pg field]
  (let [[off size] (fields field)
        ^bytes p (pager/read-page pg 1)]
    (if (== size 8) (b/u64 p off) (b/u32 p off))))

(defn set-field!
  "Set a header field, dirtying page 1."
  [pg field ^long v]
  (let [[off size] (fields field)
        ^bytes p (pager/mutable-page! pg 1)]
    (if (== size 8) (b/put-u64! p off v) (b/put-u32! p off v))
    nil))

(defn add-field!
  "Add `delta` to a header field."
  [pg field ^long delta]
  (set-field! pg field (+ (get-field pg field) delta)))

;; ---------------------------------------------------------------------------
;; Index directory

(def ^:private dir-base 128)
(def ^:private slot-size 48)

(defn- slot-off ^long [^long s] (+ dir-base (* slot-size s)))

(defn- slot-from-page
  [^bytes p ^long s]
  (let [off (slot-off s)
        live? (== 1 (b/u8 p off))]
    {:slot s
     :live? live?
     :path (when live? (b/from-utf8 (b/sub p (+ off 2) (+ off 2 (b/u8 p (inc off))))))
     :root (b/u32 p (+ off 32))
     :entries (b/u32 p (+ off 36))}))

(defn read-slot
  "Directory slot `s` as `{:slot :live? :path :root :entries}`."
  [pg ^long s]
  (slot-from-page (pager/read-page pg 1) s))

(defn live-slots
  "Live directory slots in ascending slot order."
  [pg]
  (let [^bytes p (pager/read-page pg 1)]
    (into [] (comp (filter #(== 1 (b/u8 p (slot-off %)))) (map #(slot-from-page p %)))
          (range lim/max-indexes))))

(defn find-slot
  "The live slot whose path text is `path`, or nil."
  [pg ^String path]
  (first (filter #(= path (:path %)) (live-slots pg))))

(defn first-free-slot
  "Lowest unused slot number, or nil when all are live."
  [pg]
  (let [^bytes p (pager/read-page pg 1)]
    (first (remove #(== 1 (b/u8 p (slot-off %))) (range lim/max-indexes)))))

(defn init-slot!
  "Make slot `s` live for `path` with an empty tree."
  [pg ^long s ^String path]
  (let [^bytes p (pager/mutable-page! pg 1)
        off (slot-off s)
        pb (b/utf8 path)]
    (java.util.Arrays/fill p (int off) (int (+ off slot-size)) (byte 0))
    (b/put-u8! p off 1)
    (b/put-u8! p (inc off) (alength pb))
    (b/put-bytes! p (+ off 2) pb)
    (add-field! pg :index-count 1)))

(defn clear-slot!
  "Zero all 48 bytes of slot `s`."
  [pg ^long s]
  (let [^bytes p (pager/mutable-page! pg 1)
        off (slot-off s)]
    (java.util.Arrays/fill p (int off) (int (+ off slot-size)) (byte 0))
    (add-field! pg :index-count -1)))

(defn set-slot-root! [pg ^long s ^long root]
  (b/put-u32! (pager/mutable-page! pg 1) (+ (slot-off s) 32) root)
  nil)

(defn add-slot-entries! [pg ^long s ^long delta]
  (let [^bytes p (pager/mutable-page! pg 1)
        off (+ (slot-off s) 36)]
    (b/put-u32! p off (+ (b/u32 p off) delta))
    nil))
