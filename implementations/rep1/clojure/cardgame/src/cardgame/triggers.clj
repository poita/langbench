(ns cardgame.triggers
  "Trigger collection (SPEC 13.1 - 13.2).

  An event occurring in the game *collects* triggers into the `:pending`
  list of the state; [[cardgame.chain/push-triggers!]] later orders and
  pushes them.  Each pending trigger is a map

      {:ctrl P :src oid :idx n :ts timestamp :it token}

  or, for a delayed trigger, `{:delayed d :ctrl P :src oid :idx 0 :ts ts}`.

  All of the `collect-*` functions here only record triggers; none of them
  changes anything else in the game."
  (:require [cardgame.state :as st]
            [cardgame.board :as board]))

(defn- abilities-for
  "Ability numbers of `oid`'s card listening for `event`."
  [s oid event]
  (get-in (st/obj s oid) [:def :triggers event]))

(defn- add!
  [g ctrl src idx it]
  (let [t {:ctrl ctrl :src src :idx idx :ts (:ts (st/obj @g src)) :it it}]
    (st/upd! g update :pending conj t)))

(defn collect-from!
  "Collect `event` triggers from the Field objects for which `(pred oid ctrl)`
  holds, giving each the trigger subject `it`.  Objects whose abilities are
  stripped do not listen."
  [g event pred it]
  (let [s @g]
    (when (some #(seq (abilities-for s % event)) (st/field-oids s))
      (let [d (board/derived g)]
        (doseq [oid (st/field-oids s)
                :let [idxs (abilities-for s oid event)]
                :when (and (seq idxs) (not (contains? (:stripped d) oid)))
                :let [c (get-in d [:ctrl oid])]
                :when (pred oid c)]
          (doseq [idx idxs]
            (add! g c oid idx it)))))))

(defn collect-self!
  "Collect `event` from the single object `oid`, which must be on the Field
  and not stripped."
  [g event oid it]
  (let [s @g]
    (when (and (st/on-field? s oid) (seq (abilities-for s oid event)))
      (let [d (board/derived g)]
        (when-not (contains? (:stripped d) oid)
          (doseq [idx (abilities-for s oid event)]
            (add! g (get-in d [:ctrl oid]) oid idx it)))))))

(defn collect-departed!
  "Collect `event` (`leave` or `dies`) from `oid`, which has just left the
  Field; it still listens, whether or not it was stripped.  `ctrl` is the
  controller it had when it left."
  [g event oid ctrl]
  (doseq [idx (abilities-for @g oid event)]
    (add! g ctrl oid idx oid)))

(defn collect-arrival!
  "`arrive` from the unit/relic `oid` itself, and `ally-arrive` /
  `enemy-arrive` from other Field objects when `oid` is a unit."
  [g oid]
  (collect-self! g "arrive" oid oid)
  (when (board/unit? g oid)
    (let [c (board/ctrl g oid)]
      (collect-from! g "ally-arrive" (fn [x xc] (and (not= x oid) (= xc c))) oid)
      (collect-from! g "enemy-arrive" (fn [x xc] (and (not= x oid) (not= xc c))) oid))))

(defn collect-deaths!
  "`ally-dies` / `enemy-dies` after unit `oid`, controlled by `ctrl`, died."
  [g oid ctrl]
  (when (board/unit? g oid)
    (collect-from! g "ally-dies" (fn [x xc] (and (not= x oid) (= xc ctrl))) oid)
    (collect-from! g "enemy-dies" (fn [x xc] (not= xc ctrl)) oid)))

(defn collect-spire-loss!
  "`spire-loss` and `enemy-spire-loss` after player `p` lost Spire."
  [g p]
  (collect-from! g "spire-loss" (fn [_ c] (= c p)) p)
  (collect-from! g "enemy-spire-loss" (fn [_ c] (= c (st/opp p))) p))

(defn collect-delayed!
  "Turn the delayed trigger `d` into a pending trigger."
  [g d]
  (st/upd! g update :pending conj
           {:delayed d :ctrl (:ctrl d) :src (:src d) :idx 0 :ts (:ts d) :it nil}))
