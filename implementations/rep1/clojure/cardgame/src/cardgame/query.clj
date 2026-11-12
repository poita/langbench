(ns cardgame.query
  "Evaluation of selectors, player selectors, filters, amounts and
  conditions (SPEC sections 6.3 - 6.7).

  Everything here is a pure function of an *evaluation context* `ctx`, a map
  with the keys

  * `:s`       the game state value
  * `:d`       derived characteristics (see [[cardgame.layers]]); during aura
               derivation it holds only `:ctrl`
  * `:ctrl`    the ability's controller
  * `:src`     the source object's oid
  * `:targets` the ability's target tokens, `:removed` the set of removed
               target indices (0-based)
  * `:it`      the trigger subject token, `:that` the innermost `each` object
  * `:aura?`   true while deriving an aura (amounts then use base values)
  * `:rand`    optional function `(n) -> index` consuming randomness"
  (:require [cardgame.state :as st]))

;; ---------------------------------------------------------------------------
;; Characteristics

(defn- body-of [o] (:body (:def o)))

(defn printed-edge [o] (if-let [b (body-of o)] (first b) 0))
(defn printed-core [o] (if-let [b (body-of o)] (second b) 0))

(defn base-edge
  "Printed edge plus charge counters (counters exist only on the Field)."
  [o]
  (+ (printed-edge o) (or (:counters o) 0)))

(defn base-core [o]
  (+ (printed-core o) (or (:counters o) 0)))

(defn ctrl-of
  "The current controller of object `o` for scope tests: the derived
  controller on the Field, the owner elsewhere."
  [ctx o]
  (if (= :field (:zone o))
    (or (get-in ctx [:d :ctrl (:oid o)]) (:ctrl o))
    (:owner o)))

(defn cur-edge [ctx o]
  (if (and (= :field (:zone o)) (not (:aura? ctx)))
    (get-in ctx [:d :edge (:oid o)] (base-edge o))
    (if (:aura? ctx) (base-edge o) (printed-edge o))))

(defn cur-core [ctx o]
  (if (and (= :field (:zone o)) (not (:aura? ctx)))
    (get-in ctx [:d :core (:oid o)] (base-core o))
    (if (:aura? ctx) (base-core o) (printed-core o))))

(defn cmp
  "Apply comparator keyword `c` to `a` and `b`."
  [c a b]
  (case c
    :le (<= a b) :lt (< a b) :eq (== a b) :ge (>= a b) :gt (> a b) :ne (not= a b)))

(defn has-kw? [o k]
  (boolean (some #(= k (:kw %)) (:keywords (:def o)))))

;; ---------------------------------------------------------------------------
;; Filters

(defn- obj-of [ctx oid] (st/obj (:s ctx) oid))

(defn filter-holds?
  "Does filter `f` hold for object `o` in `ctx`?  Filters test base
  characteristics."
  [ctx o f]
  (let [s (:s ctx)
        field? (= :field (:zone o))]
    (case (first f)
      :kw      (has-kw? o (second f))
      :no-kw   (not (has-kw? o (second f)))
      :tag     (boolean (some #{(second f)} (:tags (:def o))))
      :type    (= (second f) (:type (:def o)))
      :cost    (cmp (second f) (:cost (:def o)) (nth f 2))
      :edge    (cmp (second f) (base-edge o) (nth f 2))
      :core    (cmp (second f) (base-core o) (nth f 2))
      :wounded (and field? (pos? (:wounds o)))
      :ready   (and field? (boolean (:ready o)))
      :exhausted (and field? (not (:ready o)))
      :settling (st/settling? s o)
      :attacking (and field? (boolean (:attacking o)))
      :blocking  (and field? (boolean (:blocking o)))
      :mine    (= (ctrl-of ctx o) (:ctrl ctx))
      :enemy   (= (ctrl-of ctx o) (st/opp (:ctrl ctx)))
      :other   (not= (:oid o) (:src ctx))
      :not     (not (filter-holds? ctx o (second f))))))

(defn filters-hold? [ctx o fs]
  (every? #(filter-holds? ctx o %) fs))

(defn- scope-ok? [ctx scope o]
  (case scope
    :all true
    :yours (= (ctrl-of ctx o) (:ctrl ctx))
    :theirs (= (ctrl-of ctx o) (st/opp (:ctrl ctx)))))

(defn field-objects
  "Objects on the Field of the given card type (`:unit`, `:relic`, or nil
  for any), in canonical order, passing `scope` and `fs`."
  [ctx type scope fs]
  (let [s (:s ctx)
        objs (:objs s)]
    (into []
          (comp (map (fn [[_ oid]] (get objs oid)))
                (filter (fn [o]
                          (and (or (nil? type) (= type (:type (:def o))))
                               (scope-ok? ctx scope o)
                               (filters-hold? ctx o fs))))
                (map :oid))
          (:field s))))

(defn zone-objects [ctx zone scope fs]
  (let [s (:s ctx)
        oids (mapcat (fn [p] (st/zone-of s p zone)) st/players)
        objs (:objs s)]
    (->> oids
         (map #(get objs %))
         (filter (fn [o] (and (scope-ok? ctx scope o) (filters-hold? ctx o fs))))
         (sort-by (fn [o] [(:ts o) (:oid o)]))
         (mapv :oid))))

;; ---------------------------------------------------------------------------
;; Selectors

(defn target-token
  "The n-th (1-based) target of the ability, or nil when absent or removed."
  [ctx n]
  (let [i (dec n)]
    (when (and (< -1 i (count (:targets ctx))) (not (contains? (:removed ctx) i)))
      (nth (:targets ctx) i))))

(defn objects
  "The objects selected by object selector `sel`, as a vector of oids in
  canonical order."
  [ctx sel]
  (cond
    (= sel :self) (if-let [o (:src ctx)] [o] [])
    (= sel :it)   (let [t (:it ctx)] (if (integer? t) [t] []))
    (= sel :that) (if-let [t (:that ctx)] [t] [])
    :else
    (case (first sel)
      :t (let [t (target-token ctx (second sel))] (if (integer? t) [t] []))
      :units  (field-objects ctx :unit (second sel) (nth sel 2))
      :relics (field-objects ctx :relic (second sel) (nth sel 2))
      :cards  (zone-objects ctx (second sel) (nth sel 2) (nth sel 3))
      :random-unit
      (let [lst (field-objects ctx :unit (second sel) (nth sel 2))]
        (if (empty? lst)
          []
          (let [f (:rand ctx)]
            [(nth lst (f (count lst)))]))))))

(defn players
  "The players selected by player selector `psel`, A before B."
  [ctx psel]
  (cond
    (= psel :you)  [(:ctrl ctx)]
    (= psel :foe)  [(st/opp (:ctrl ctx))]
    (= psel :both) [:A :B]
    :else
    (case (first psel)
      :t (let [t (target-token ctx (second psel))] (if (keyword? t) [t] []))
      :owner-of
      (let [inner (second psel)]
        (if (and (vector? inner) (= :t (first inner)) (keyword? (target-token ctx (second inner))))
          [(target-token ctx (second inner))]
          (let [owners (set (map #(:owner (obj-of ctx %)) (objects ctx inner)))]
            (filterv owners [:A :B])))))))

(defn damage-targets
  "Tokens yielded by a damage selector, in ascending target-key order."
  [ctx dsel]
  (cond
    (or (#{:you :foe :both} dsel) (and (vector? dsel) (= :owner-of (first dsel))))
    (players ctx dsel)

    (and (vector? dsel) (= :t (first dsel)))
    (let [t (target-token ctx (second dsel))]
      (if (or (keyword? t) (integer? t)) [t] []))

    :else (objects ctx dsel)))

;; ---------------------------------------------------------------------------
;; Amounts and conditions

(defn- sum-players [ctx psel f]
  (reduce + 0 (map f (players ctx psel))))

(defn amount [ctx amt]
  (if (integer? amt)
    amt
    (let [s (:s ctx)]
      (case (first amt)
        :count  (count (objects ctx (second amt)))
        :hand   (sum-players ctx (second amt) #(st/hand-size s %))
        :ash    (sum-players ctx (second amt) #(st/ash-size s %))
        :vault  (sum-players ctx (second amt) #(st/vault-size s %))
        :edge   (reduce + 0 (map #(cur-edge ctx (obj-of ctx %)) (objects ctx (second amt))))
        :core   (reduce + 0 (map #(cur-core ctx (obj-of ctx %)) (objects ctx (second amt))))
        :wounds (reduce + 0 (map #(let [o (obj-of ctx %)]
                                    (if (= :field (:zone o)) (:wounds o) 0))
                                 (objects ctx (second amt))))))))

(defn condition [ctx c]
  (let [s (:s ctx)]
    (case (first c)
      :count (cmp (nth c 2) (count (objects ctx (second c))) (nth c 3))
      :spire (cmp (nth c 2) (sum-players ctx (second c) #(st/pl s % :spire)) (nth c 3))
      :ember (cmp (nth c 2) (sum-players ctx (second c) #(st/pl s % :ember)) (nth c 3))
      :hand  (cmp (nth c 2) (sum-players ctx (second c) #(st/hand-size s %)) (nth c 3))
      :ash   (cmp (nth c 2) (sum-players ctx (second c) #(st/ash-size s %)) (nth c 3))
      :vault (cmp (nth c 2) (sum-players ctx (second c) #(st/vault-size s %)) (nth c 3))
      :myturn (= (:active s) (:ctrl ctx))
      :and (every? #(condition ctx %) (second c))
      :or  (boolean (some #(condition ctx %) (second c)))
      :not (not (condition ctx (second c))))))

(defn cardfilter-holds?
  "Test a `cheaper` card filter against the printed characteristics of
  `card`."
  [card f]
  (case (first f)
    :type (= (second f) (:type card))
    :tag  (boolean (some #{(second f)} (:tags card)))
    :cost (cmp (second f) (:cost card) (nth f 2))))
