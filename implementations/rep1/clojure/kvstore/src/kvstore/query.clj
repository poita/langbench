(ns kvstore.query
  "Predicate evaluation, plan selection and `find` (spec section 17)."
  (:require [clojure.string :as str]
            [kvstore.btree :as bt]
            [kvstore.bytes :as b]
            [kvstore.docs :as docs]
            [kvstore.header :as h]
            [kvstore.index :as ix]
            [kvstore.value :as v]))

(set! *warn-on-reflection* true)

(defn- compare-op?
  "Evaluate `x op value` for a present `x`."
  [op x value]
  (let [same-rank? (== (v/type-rank x) (v/type-rank value))]
    (case op
      "==" (and same-rank? (= x value))
      "!=" (not (and same-rank? (= x value)))
      (and same-rank?
           (not (v/container? x))
           (let [c (long (v/same-rank-compare x value))]
             (case op
               "<" (neg? c)
               "<=" (<= c 0)
               ">" (pos? c)
               ">=" (>= c 0)))))))

(defn matches?
  "Does document `doc` satisfy predicate `pred`?"
  [pred doc]
  (case (nth pred 0)
    :and (and (matches? (nth pred 1) doc) (matches? (nth pred 2) doc))
    :or (or (matches? (nth pred 1) doc) (matches? (nth pred 2) doc))
    :not (not (matches? (nth pred 1) doc))
    :exists (not (identical? v/missing (v/resolve-path doc (nth pred 1))))
    :missing (identical? v/missing (v/resolve-path doc (nth pred 1)))
    :cmp (let [x (v/resolve-path doc (nth pred 2))]
           (and (not (identical? x v/missing))
                (compare-op? (nth pred 1) x (nth pred 3))))))

(defn- flatten-and
  "Leaves of the `and` spine of `pred`, left to right."
  [pred]
  (if (= :and (nth pred 0))
    (into (flatten-and (nth pred 1)) (flatten-and (nth pred 2)))
    [pred]))

(defn choose-plan
  "The best usable leaf of `pred` as `{:slot :path :op :value}`, or nil for a
  `scan` plan (spec 17.3)."
  [pg pred]
  (let [usable (into []
                     (keep-indexed
                      (fn [i leaf]
                        (when (and (= :cmp (nth leaf 0))
                                   (not= "!=" (nth leaf 1))
                                   (not (v/container? (nth leaf 3))))
                          (let [text (str/join "." (nth leaf 2))]
                            (when-let [slot (h/find-slot pg text)]
                              {:slot (:slot slot) :path text :op (nth leaf 1)
                               :value (nth leaf 3) :pos i})))))
                     (flatten-and pred))]
    ;; paths are ASCII (WORD characters), so string order is byte order
    (first (sort-by (juxt #(if (= "==" (:op %)) 0 1) :path :pos) usable))))

(defn find-docs
  "Run `find`.  Returns `{:plan \"scan\"|\"index <path>\" :rows [[key-bytes doc] ...]}`
  with rows in ascending primary key order, at most `limit` of them."
  [pg pred limit]
  (let [plan (choose-plan pg pred)
        cells (if plan
                (->> (ix/candidates pg (:slot plan) (:op plan) (:value plan))
                     (map ix/doc-key-of)
                     (sort b/compare-bytes)
                     (keep #(bt/search pg docs/primary %)))
                (bt/cells-from pg docs/primary nil))
        rows (->> cells
                  (map (fn [cell] [(:key cell) (docs/cell-doc pg cell)]))
                  (filter (fn [[_ doc]] (matches? pred doc))))]
    {:plan (if plan (str "index " (:path plan)) "scan")
     :rows (vec (if limit (take limit rows) rows))}))
