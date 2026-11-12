(ns orderbook.model-test
  "Property test: the engine agrees with a deliberately naive reference
  model (a flat vector of resting orders, scanned linearly) on random
  command sequences."
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [orderbook.core :as ob]))

;; ---------------------------------------------------------------- model

(defn- crosses? [side limit price]
  (or (nil? limit)
      (if (= side :buy) (<= price limit) (>= price limit))))

(defn- match [{:keys [orders] :as st} taker side limit qty]
  (let [opp (if (= side :buy) :sell :buy)
        cand (filter #(and (= opp (:side %)) (crosses? side limit (:price %))) orders)]
    (if (or (zero? qty) (empty? cand))
      [st qty []]
      (let [m (reduce (fn [a b]
                        (let [ka [(if (= opp :sell) (:price a) (- (:price a))) (:seq a)]
                              kb [(if (= opp :sell) (:price b) (- (:price b))) (:seq b)]]
                          (if (neg? (compare ka kb)) a b)))
                      cand)
            t (min qty (:qty m))
            evs (cond-> [{:event :trade :taker taker :maker (:id m) :price (:price m) :qty t}]
                  (= t (:qty m)) (conj {:event :filled :id (:id m)}))
            st' (update st :orders
                        (fn [os] (if (= t (:qty m))
                                   (filterv #(not= (:id %) (:id m)) os)
                                   (mapv #(if (= (:id %) (:id m)) (update % :qty - t) %) os))))
            [st'' rem more] (match st' taker side limit (- qty t))]
        [st'' rem (into evs more)]))))

(defn- finish [st id side price rem rest? evs]
  (cond
    (zero? rem) [st (conj evs {:event :filled :id id})]
    rest? [(-> st
               (update :orders conj {:id id :side side :price price :qty rem :seq (:next st)})
               (update :next inc))
           (conj evs {:event :rest :id id})]
    :else [st (conj evs {:event :cancel :id id :qty rem})]))

(defn- avail [{:keys [orders]} side limit]
  (let [opp (if (= side :buy) :sell :buy)]
    (reduce + 0 (map :qty (filter #(and (= opp (:side %)) (crosses? side limit (:price %))) orders)))))

(defn- level-lines [orders side]
  (let [by (group-by :price (filter #(= side (:side %)) orders))
        prices (sort-by (if (= side :buy) - identity) (keys by))]
    (mapv (fn [p] {:event (if (= side :buy) :bid :ask) :price p
                   :qty (reduce + (map :qty (by p))) :orders (count (by p))})
          prices)))

(defn- model-step [{:keys [orders] :as st} cmd]
  (let [find-o (fn [id] (first (filter #(= id (:id %)) orders)))]
    (case (:op cmd)
      :limit (let [{:keys [id side price qty tif]} cmd]
               (cond
                 (find-o id) [st [{:event :reject :id id}]]
                 (and (= tif :fok) (< (avail st side price) qty)) [st [{:event :reject :id id}]]
                 :else (let [[st' rem evs] (match st id side price qty)]
                         (finish st' id side price rem (= tif :gtc) evs))))
      :market (let [{:keys [id side qty]} cmd]
                (if (find-o id)
                  [st [{:event :reject :id id}]]
                  (let [[st' rem evs] (match st id side nil qty)]
                    (finish st' id side nil rem false evs))))
      :cancel (if-let [o (find-o (:id cmd))]
                [(update st :orders (fn [os] (filterv #(not= (:id %) (:id o)) os)))
                 [{:event :cancel :id (:id o) :qty (:qty o)}]]
                [st [{:event :reject :id (:id cmd)}]])
      :replace (if-let [o (find-o (:id cmd))]
                 (if (and (= (:price cmd) (:price o)) (<= (:qty cmd) (:qty o)))
                   [(update st :orders (fn [os] (mapv #(if (= (:id %) (:id o)) (assoc % :qty (:qty cmd)) %) os)))
                    [{:event :rest :id (:id o)}]]
                   (let [st0 (update st :orders (fn [os] (filterv #(not= (:id %) (:id o)) os)))
                         [st' rem evs] (match st0 (:id o) (:side o) (:price cmd) (:qty cmd))]
                     (finish st' (:id o) (:side o) (:price cmd) rem true evs)))
                 [st [{:event :reject :id (:id cmd)}]])
      :book [st (-> (level-lines orders :buy)
                    (into (level-lines orders :sell))
                    (conj {:event :book-end}))])))

(defn run-model [cmds]
  (loop [st {:orders [] :next 0} cmds cmds out []]
    (if-let [[c & more] (seq cmds)]
      (let [[st' evs] (model-step st c)]
        (recur st' more (conj out evs)))
      out)))

(defn run-engine [cmds]
  (let [b (ob/new-book)]
    (mapv #(ob/execute! b %) cmds)))

;; ------------------------------------------------------------ generators

(def gen-id (gen/elements ["a" "b" "c" "d" "e" "f" "g" "h" "i" "j" "k" "l" "BUY" "BOOK"]))
(def gen-side (gen/elements [:buy :sell]))
(def gen-price (gen/choose 95 105))
(def gen-qty (gen/one-of [(gen/choose 1 6) (gen/return 1000000000)]))

(def gen-command
  (gen/frequency
   [[10 (gen/fmap (fn [[id s p q tif]] {:op :limit :id id :side s :price p :qty q :tif tif})
                  (gen/tuple gen-id gen-side gen-price gen-qty
                             (gen/frequency [[6 (gen/return :gtc)] [2 (gen/return :ioc)] [2 (gen/return :fok)]])))]
    [2 (gen/fmap (fn [[id s q]] {:op :market :id id :side s :qty q})
                 (gen/tuple gen-id gen-side gen-qty))]
    [3 (gen/fmap (fn [id] {:op :cancel :id id}) gen-id)]
    [4 (gen/fmap (fn [[id p q]] {:op :replace :id id :price p :qty q})
                 (gen/tuple gen-id gen-price gen-qty))]
    [2 (gen/return {:op :book})]]))

;; Ids are only ever submitted once, as in the real input; the generator
;; renames each LIMIT/MARKET to a fresh id and points CANCEL/REPLACE at
;; any id used so far or a never-used one.
(defn- uniquify [cmds]
  (let [used (atom [])]
    (mapv (fn [c]
            (case (:op c)
              (:limit :market)
              (let [id (str "o" (count @used))]
                (swap! used conj id)
                (assoc c :id id))
              (:cancel :replace)
              (assoc c :id (if (and (seq @used) (not= "BUY" (:id c)))
                             (nth @used (mod (hash (:id c)) (count @used)))
                             "never"))
              c))
          cmds)))

(def gen-commands (gen/fmap uniquify (gen/vector gen-command 0 80)))

(defspec engine-matches-reference-model 1000
  (prop/for-all [cmds gen-commands]
    (= (run-model cmds) (run-engine cmds))))

(defspec book-is-never-crossed 500
  (prop/for-all [cmds gen-commands]
    (let [b (ob/new-book)]
      (doseq [c cmds] (ob/execute! b c))
      (let [{:keys [bids asks]} (ob/snapshot b)]
        (or (empty? bids) (empty? asks)
            (< (:price (first bids)) (:price (first asks))))))))

(deftest model-sanity
  (is (= [[{:event :rest :id "a"}]] (run-model [{:op :limit :id "a" :side :buy :price 1 :qty 1 :tif :gtc}]))))
