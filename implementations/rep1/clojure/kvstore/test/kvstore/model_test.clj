(ns kvstore.model-test
  "Property tests: random workloads are replayed against a plain sorted map
  and against the store; contents, index results, page accounting and
  recovery must agree."
  (:require [clojure.test :refer [is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [kvstore.btree :as bt]
            [kvstore.bytes :as b]
            [kvstore.core :as kv]
            [kvstore.docs :as docs]
            [kvstore.header :as h]
            [kvstore.overflow :as ovf]
            [kvstore.pager :as pager]))

(def gen-key (gen/fmap #(str "key-" (format "%03d" %)) (gen/choose 0 120)))

(def gen-doc
  (gen/one-of
   [(gen/fmap (fn [n] {"n" n "tag" (str "t" (mod n 5))}) (gen/choose 0 9))
    (gen/fmap (fn [n] {"n" n "pad" (apply str (repeat (* n 40) "p"))}) (gen/choose 0 40))
    gen/small-integer
    (gen/vector gen/small-integer 0 30)]))

(def gen-op
  (gen/frequency
   [[6 (gen/fmap (fn [[k d]] [:put k d]) (gen/tuple gen-key gen-doc))]
    [4 (gen/fmap (fn [k] [:delete k]) gen-key)]
    [2 (gen/fmap (fn [[k n]] [:update k n]) (gen/tuple gen-key (gen/choose 0 9)))]
    [1 (gen/fmap (fn [k] [:unset k]) gen-key)]
    [1 (gen/return [:checkpoint])]
    [1 (gen/return [:begin])]
    [1 (gen/return [:commit])]
    [1 (gen/return [:rollback])]]))

(defn- ok [f] (try (f) true (catch clojure.lang.ExceptionInfo _ false)))

(defn- apply-op!
  "Apply an op to the store and, when it succeeds, to the model.  `state` is
  `{:model m :committed m :open? bool}`."
  [db {:keys [model committed open?] :as state} [op k x]]
  (case op
    :put (do (kv/put! db k x) (assoc state :model (assoc model k x)))
    :delete (if (ok #(kv/delete! db k)) (assoc state :model (dissoc model k)) state)
    :update (if (ok #(kv/update! db k "n" x))
              (assoc state :model (update model k assoc "n" x))
              state)
    :unset (if (ok #(kv/unset! db k "n"))
             (assoc state :model (update model k dissoc "n"))
             state)
    :checkpoint (do (when-not open? (kv/checkpoint! db)) state)
    :begin (if open? state (do (kv/begin! db) (assoc state :open? true :committed model)))
    :commit (if open? (do (kv/commit! db) (assoc state :open? false)) state)
    :rollback (if open? (do (kv/rollback! db) (assoc state :open? false :model committed)) state)))

(defn- reachable-pages
  "Number of pages in a tree rooted at `root`, plus overflow pages when `primary?`."
  [pg root primary?]
  (if (zero? root)
    0
    (let [node (bt/read-node pg root)]
      (if (= bt/interior (:type node))
        (+ 1
           (reduce + (map #(reachable-pages pg (:child %) primary?) (:cells node)))
           (reachable-pages pg (:link node) primary?))
        (+ 1 (if primary?
               (reduce + (map #(count (ovf/chain-pages pg (:overflow %))) (:cells node)))
               0))))))

(defn- pages-add-up?
  "Every page is the header, reachable from a tree, or on the free list."
  [db]
  (let [total (h/get-field db :page-count)
        primary (reachable-pages db (h/get-field db :primary-root) true)
        indexes (reduce + (map #(reachable-pages db (:root %) false) (h/live-slots db)))
        free (h/get-field db :freelist-count)]
    (= total (+ 1 primary indexes free))))

(defn- run [ops]
  (let [db (kv/open)
        _ (kv/create-index! db "n")
        end (reduce (fn [state op] (apply-op! db state op))
                    {:model {} :committed {} :open? false} ops)]
    [db end]))

(defspec store-matches-a-sorted-map 40
  (prop/for-all [ops (gen/vector gen-op 1 150)]
    (let [[db {:keys [model open?]}] (run ops)]
      (and (= (vec (sort-by key model)) (kv/scan db))
           (= (count model) (:docs (kv/stat db)))
           (pages-add-up? db)
           (every? (fn [n]
                     (= (keep (fn [[k d]] (when (and (map? d) (= n (get d "n"))) k)) (sort-by key model))
                        (map first (:rows (kv/find db (str "n == " n))))))
                   (range 10))
           (= (keep (fn [[k d]] (when (and (map? d) (integer? (get d "n")) (>= (get d "n") 7)) k))
                    (sort-by key model))
              (map first (:rows (kv/find db "n >= 7"))))
           (or open?
               (let [reopened (kv/open (kv/files db))]
                 (= (kv/scan db) (kv/scan reopened))))))))

(defspec rollback-leaves-no-trace 25
  (prop/for-all [setup (gen/vector gen-op 1 60)
                 more (gen/vector gen-op 1 40)]
    (let [[db {:keys [open?]}] (run setup)]
      (when open? (kv/rollback! db))
      (let [before (kv/files db)]
        (kv/begin! db)
        (reduce (fn [state op] (if (#{:begin :commit :rollback :checkpoint} (first op))
                                 state
                                 (apply-op! db state op)))
                {:model {} :committed {} :open? true} more)
        (kv/rollback! db)
        (and (b/bytes= (:main before) (:main (kv/files db)))
             (b/bytes= (:wal before) (:wal (kv/files db))))))))

(defspec recovery-keeps-exactly-the-committed-prefix 20
  (prop/for-all [ops (gen/vector (gen/fmap (fn [[k d]] [:put k d]) (gen/tuple gen-key gen-doc)) 2 30)
                 frac (gen/double* {:min 0.0 :max 1.0 :NaN? false})]
    (let [db (kv/open)
          sizes (mapv (fn [[_ k d]] (kv/put! db k d) (:wal (kv/stat db))) ops)
          wal (:wal (kv/files db))
          cut (long (* frac (alength ^bytes wal)))
          surviving (count (take-while #(<= % cut) sizes))
          reopened (kv/open {:wal (b/sub wal 0 cut)})
          expected (reduce (fn [m [_ k d]] (assoc m k d)) {} (take surviving ops))]
      (= (vec (sort-by key expected)) (kv/scan reopened)))))
