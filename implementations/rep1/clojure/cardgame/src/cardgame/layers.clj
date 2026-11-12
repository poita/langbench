(ns cardgame.layers
  "The layer system (SPEC section 14): derivation of the current
  characteristics of every object on the Field.

  [[derive-board]] is a pure function of the game state.  It produces a map

  * `:ctrl`     oid -> current controller (layer 1)
  * `:stripped` set of oids whose keywords and abilities were stripped
  * `:kws`      oid -> vector of keyword instances (layer 2)
  * `:edge`, `:core`  oid -> current edge / core (layers 3-6)
  * `:auras`    eid -> `{:active? :leaves [...]}` for every aura record,
                each leaf `{:kind :args :objs :desc}`
  * `:cheaper`  vector of active `cheaper` leaves `{:ctrl :n :filters}`

  Records are applied lowest layer first, each layer in ascending
  `(timestamp, eid)` order.  Record vectors are kept in creation order, which
  is that order."
  (:require [cardgame.state :as st]
            [cardgame.query :as q]
            [cardgame.cards :as cards]))

(defn- kw-str [{:keys [kw n]}]
  (if (= kw "plating") (str "plating:" n) kw))

(defn- eval-leaf
  "Evaluate one non-`when` static under `ctx`, activity `active?`.  Returns
  a leaf map."
  [ctx static active?]
  (let [objs (fn [sel] (if active? (q/objects ctx sel) []))]
    (case (first static)
      :modify {:kind :modify
               :args [(q/amount ctx (nth static 1)) (q/amount ctx (nth static 2))]
               :objs (objs (nth static 3))
               :desc (str "modify " (q/amount ctx (nth static 1)) " " (q/amount ctx (nth static 2)))}
      :setbody {:kind :setbody
                :args [(q/amount ctx (nth static 1)) (q/amount ctx (nth static 2))]
                :objs (objs (nth static 3))
                :desc (str "setbody " (q/amount ctx (nth static 1)) " " (q/amount ctx (nth static 2)))}
      :swapstats {:kind :swapstats :args [] :objs (objs (nth static 1)) :desc "swapstats"}
      :grant {:kind :grant :args [(nth static 1)] :objs (objs (nth static 2))
              :desc (str "grant " (kw-str (nth static 1)))}
      :cheaper {:kind :cheaper :args [(nth static 1) (nth static 2)] :objs []
                :active? active?
                :desc (str "cheaper " (nth static 1))})))

(defn- eval-statics
  "Flatten `statics` (which may contain `when` wrappers) into leaves."
  [ctx statics active?]
  (mapcat (fn [st]
            (if (= :when (first st))
              (eval-statics ctx (nth st 2) (and active? (q/condition ctx (nth st 1))))
              [(eval-leaf ctx st active?)]))
          statics))

(defn- layer-of [kind]
  (case kind :grant 2 :strip 2 :setbody 3 :modify 4 :swapstats 6))

(defn derive-board
  "Derive current characteristics from state `s`."
  [s]
  (let [objs (:objs s)
        field (vec (st/field-oids s))
        records (:records s)
        ;; Layer 1
        ctrl (reduce (fn [m oid] (assoc m oid (:ctrl (get objs oid)))) {} field)
        ctrl (reduce (fn [m r]
                       (if (= :control (:kind r))
                         (reduce (fn [m oid] (if (contains? m oid) (assoc m oid (:ctrl r)) m))
                                 m (:affected r))
                         m))
                     ctrl records)
        ;; stripped set
        stripped (reduce (fn [acc r]
                           (if (= :strip (:kind r))
                             (into acc (filter #(contains? ctrl %)) (:affected r))
                             acc))
                         #{} records)
        ;; Aura records
        auras
        (reduce
         (fn [m r]
           (if (= :aura (:dur r))
             (let [src (:src r)
                   active? (not (contains? stripped src))
                   rc (get ctrl src)
                   ctx {:s s :d {:ctrl ctrl} :ctrl rc :src src :aura? true}
                   statics (:statics (nth (:abilities (:def (get objs src))) (dec (:ab r))))
                   leaves (vec (eval-statics ctx statics active?))]
               (assoc m (:eid r) {:active? active? :ctrl rc :leaves leaves}))
             m))
         {} records)
        ;; Gather layer items in (ts, eid) order
        items
        (into []
              (mapcat
               (fn [r]
                 (if (= :aura (:dur r))
                   (let [a (get auras (:eid r))]
                     (for [l (:leaves a) :when (#{:modify :setbody :swapstats :grant} (:kind l))]
                       {:layer (layer-of (:kind l)) :kind (:kind l) :args (:args l)
                        :objs (:objs l)}))
                   (when (#{:modify :setbody :swapstats :grant :strip} (:kind r))
                     [{:layer (layer-of (:kind r)) :kind (:kind r) :args (:args r)
                       :objs (filterv #(contains? ctrl %) (:affected r))}]))))
              records)
        ;; Layer 2: keywords
        kws (reduce (fn [m oid] (assoc m oid (:keywords (:def (get objs oid))))) {} field)
        kws (reduce (fn [m it]
                      (case (:kind it)
                        :grant (reduce (fn [m oid] (update m oid conj (first (:args it)))) m (:objs it))
                        :strip (reduce (fn [m oid] (assoc m oid [])) m (:objs it))
                        m))
                    kws items)
        ;; Layers 3-6
        edge0 (reduce (fn [m oid] (assoc m oid (q/printed-edge (get objs oid)))) {} field)
        core0 (reduce (fn [m oid] (assoc m oid (q/printed-core (get objs oid)))) {} field)
        [e c] (reduce (fn [[e c] it]
                        (if (= :setbody (:kind it))
                          [(reduce #(assoc %1 %2 (first (:args it))) e (:objs it))
                           (reduce #(assoc %1 %2 (second (:args it))) c (:objs it))]
                          [e c]))
                      [edge0 core0] items)
        [e c] (reduce (fn [[e c] it]
                        (if (= :modify (:kind it))
                          [(reduce #(update %1 %2 + (first (:args it))) e (:objs it))
                           (reduce #(update %1 %2 + (second (:args it))) c (:objs it))]
                          [e c]))
                      [e c] items)
        [e c] (reduce (fn [[e c] oid]
                        (let [n (:counters (get objs oid) 0)]
                          (if (pos? n) [(update e oid + n) (update c oid + n)] [e c])))
                      [e c] field)
        [e c] (reduce (fn [[e c] it]
                        (if (= :swapstats (:kind it))
                          (reduce (fn [[e c] oid] [(assoc e oid (get c oid)) (assoc c oid (get e oid))])
                                  [e c] (:objs it))
                          [e c]))
                      [e c] items)
        cheaper (into []
                      (mapcat (fn [r]
                                (if (= :aura (:dur r))
                                  (let [a (get auras (:eid r))]
                                    (for [l (:leaves a)
                                          :when (and (= :cheaper (:kind l)) (:active? l))]
                                      {:ctrl (:ctrl a) :n (first (:args l)) :filters (second (:args l))}))
                                  nil)))
                      records)]
    {:ctrl ctrl :stripped stripped :kws kws :edge e :core c :auras auras
     :cheaper cheaper
     :reads (reduce (fn [acc r]
                      (if (= :aura (:dur r))
                        (into acc (:reads (nth (:abilities (:def (get objs (:src r)))) (dec (:ab r)))))
                        acc))
                    #{} records)}))
