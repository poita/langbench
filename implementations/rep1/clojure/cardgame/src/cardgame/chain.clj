(ns cardgame.chain
  "The Chain, priority-independent parts of play: playing cards,
  activating abilities, resolving entries, pushing triggers, state checks
  and `settle` / `drain` (SPEC sections 10.5, 10.6, 11, 13.3, 18)."
  (:require [cardgame.state :as st :refer [emit! render]]
            [cardgame.board :as board]
            [cardgame.query :as q]
            [cardgame.rules :as rules]
            [cardgame.effects :as fx]
            [cardgame.targeting :as tgt]
            [cardgame.triggers :as trig]))

;; ---------------------------------------------------------------------------
;; State checks and trigger pushing

(defn- state-checks!
  "18: one run of the state checks.  Returns true when it acted."
  [g]
  (doseq [p st/players]
    (when (<= (st/pl @g p :spire) 0)
      (rules/record-loss! g p "spire")))
  (when (seq (:loss @g))
    (rules/end-match! g))
  (let [s @g
        d (board/derived g)
        doomed (filterv (fn [oid]
                          (let [o (st/obj s oid)]
                            (and (= :unit (:type (:def o)))
                                 (or (:doomed o)
                                     (<= (get-in d [:core oid]) (:wounds o))))))
                        (st/field-oids s))]
    (when (seq doomed)
      (doseq [oid doomed]
        (when (st/on-field? @g oid)
          (rules/destroy! g oid)))
      true)))

(defn- trigger-key [active t]
  [(if (= (:ctrl t) active) 0 1) (:ts t) (:src t) (:idx t)])

(defn- ability-of [card n] (nth (:abilities card) (dec n)))

(defn- push-triggers!
  "13.3: order the pending triggers, choose their targets, and push the
  survivors onto the Chain.  Returns true when the pending list was
  non-empty."
  [g]
  (let [pending (:pending @g)]
    (when (seq pending)
      (st/upd! g assoc :pending [])
      (let [active (:active @g)
            ordered (sort-by #(trigger-key active %) pending)
            entries
            (reduce
             (fn [acc t]
               (let [card (:def (st/obj @g (:src t)))
                     d (:delayed t)
                     ab (when-not d (ability-of card (:idx t)))
                     tspecs (if d (:tspecs d) (:targets ab))
                     targets (cond d (:targets d)
                                   (empty? tspecs) []
                                   :else (tgt/auto-targets g tspecs (:ctrl t) (:src t)))]
                 (if (nil? targets)
                   (do (emit! g "TRIGGER-NO-TARGET" (name (:ctrl t)) (render (:src t)) (:idx t))
                       acc)
                   (let [cid (st/next-cid! g)]
                     (apply emit! g "TRIGGER" (name (:ctrl t)) (render [:c cid])
                            (render (:src t)) (:idx t) (map render targets))
                     (conj acc {:cid cid :kind :trigger :ctrl (:ctrl t) :src (:src t)
                                :idx (:idx t) :targets targets :tspecs (vec tspecs)
                                :effects (if d (:effects d) (:effects ab))
                                :it (:it t)})))))
             [] ordered)]
        (st/upd! g update :chain into (reverse entries))
        true))))

(defn settle!
  "10.5: run the state checks and push triggers until nothing changes.
  Returns true when anything happened.  May end the match."
  [g]
  (loop [acted false]
    (let [a (state-checks! g)
          b (push-triggers! g)]
      (if (or a b) (recur true) acted))))

;; ---------------------------------------------------------------------------
;; Resolution

(defn- entry-ctx [e removed]
  {:ctrl (:ctrl e) :src (:src e) :targets (:targets e) :removed removed
   :tspecs (:tspecs e) :it (:it e)})

(defn resolve-top!
  "11.6: resolve the entry on top of the Chain."
  [g]
  (let [e (peek (:chain @g))
        cid (:cid e)]
    (emit! g "RESOLVE" (render [:c cid]))
    (let [removed (set (keep-indexed
                        (fn [i t]
                          (when-not (tgt/legal-target? g (nth (:tspecs e) i) t (:ctrl e) (:src e) cid)
                            i))
                        (:targets e)))
          n (count (:targets e))
          fizzled? (and (pos? n) (= n (count removed)))]
      (if fizzled?
        (emit! g "FIZZLE" (render [:c cid]))
        (case (:kind e)
          :rite (fx/execute! g (entry-ctx e removed) (:effects e))
          (:unit :relic)
          (do (st/upd! g update :chain (fn [c] (filterv #(not= cid (:cid %)) c)))
              (rules/enter-field! g (:src e) (:ctrl e)))
          (:ability :trigger) (fx/execute! g (entry-ctx e removed) (:effects e))))
      (st/upd! g update :chain (fn [c] (filterv #(not= cid (:cid %)) c)))
      (case (:kind e)
        :rite (let [o (st/obj @g (:src e))]
                (st/zone-append! g (:src e) :ash)
                (emit! g "SPENT" (render (:src e)) (:cid o)))
        (:unit :relic) (when fizzled?
                         (st/zone-append! g (:src e) :ash))
        nil))))

(defn drain!
  "10.6: settle and resolve until the Chain is empty."
  [g]
  (loop []
    (settle! g)
    (when (seq (:chain @g))
      (resolve-top! g)
      (recur))))

;; ---------------------------------------------------------------------------
;; Playing cards

(defn play-cost
  "11.2 step 4: the Ember cost for `player` to play card `oid`."
  [g player oid]
  (let [card (:def (st/obj @g oid))
        disc (reduce + 0 (keep (fn [r]
                                 (when (and (= player (:ctrl r))
                                            (every? #(q/cardfilter-holds? card %) (:filters r)))
                                   (:n r)))
                               (:cheaper (board/derived g))))]
    (max 0 (- (:cost card) disc))))

(defn play-timing-ok?
  "11.1: may `player` play card `oid` now?"
  [g player oid]
  (let [s @g
        card (:def (st/obj s oid))]
    (if (and (= :rite (:type card)) (some #(= "swift" (:kw %)) (:keywords card)))
      true
      (and (= player (:active s))
           (#{:main1 :main2} (:step s))
           (empty? (:chain s))))))

(defn card-tspecs
  "The target specifications of the card's `resolve` ability (none for a
  unit or relic)."
  [card]
  (if (= :rite (:type card))
    (:targets (first (:abilities card)))
    []))

(defn check-play
  "Validate a PLAY of hand position `pos` (1-based) with `targets` (tokens).
  Returns an error kind keyword or nil."
  [g player pos targets]
  (let [s @g
        hand (st/zone-of s player :hand)]
    (cond
      (or (< pos 1) (> pos (count hand))) :no-such-card
      :else
      (let [oid (nth hand (dec pos))
            card (:def (st/obj s oid))
            tspecs (card-tspecs card)]
        (cond
          (not (play-timing-ok? g player oid)) :bad-timing
          (not= (count targets) (count tspecs)) :bad-target-count
          (or (not= (count targets) (count (set targets)))
              (not (every? true? (map #(tgt/legal-target? g %1 %2 player oid nil) tspecs targets))))
          :illegal-target
          (> (play-cost g player oid) (st/pl s player :ember)) :cannot-afford
          :else nil)))))

(defn play!
  "11.2: play the card at hand position `pos`; `check-play` must have
  passed."
  [g player pos targets]
  (let [oid (nth (st/zone-of @g player :hand) (dec pos))
        card (:def (st/obj @g oid))
        cost (play-cost g player oid)
        cid (st/next-cid! g)
        kind (:type card)
        ab (when (= kind :rite) (first (:abilities card)))]
    (st/zone-remove! g oid)
    (st/set-obj! g oid :zone :chain)
    (st/upd! g update :chain conj
             {:cid cid :kind kind :ctrl player :src oid :idx 0 :targets (vec targets)
              :tspecs (vec (:targets ab)) :effects (:effects ab) :it nil})
    (apply emit! g "PLAY" (name player) (render [:c cid]) (render oid) (:id card)
           (map render targets))
    (st/update-pl! g player :ember - cost)
    (when (pos? cost) (emit! g "PAY" (name player) "ember" cost))
    (when (= kind :rite)
      (trig/collect-from! g "you-play-rite" (fn [_ c] (= c player)) oid)
      (trig/collect-from! g "enemy-plays-rite" (fn [_ c] (= c (st/opp player))) oid))))

;; ---------------------------------------------------------------------------
;; Activating abilities

(defn- cost-payable?
  "11.3 step 4 for a single cost item."
  [g player src ab-n item]
  (let [s @g
        o (st/obj s src)]
    (case (first item)
      :ember (>= (st/pl s player :ember) (second item))
      :spire true
      :discard (>= (st/hand-size s player) (second item))
      :exhaust (and (= :field (:zone o)) (:ready o)
                    (or (not (st/settling? s o)) (board/has-kw? g src "vanguard")))
      :sacself (= :field (:zone o))
      :counters (and (= :field (:zone o)) (>= (:counters o) (second item)))
      :once (not (contains? (:once o) ab-n)))))

(defn costs-payable? [g player src ab]
  (every? #(cost-payable? g player src (:n ab) %) (:cost ab)))

(defn activatable-ability
  "The `act` ability number `n` of `src`'s card, or nil when `n` does not
  name one or the object's abilities are stripped."
  [g src n]
  (let [card (:def (board/obj g src))
        ab (when (and (integer? n) (<= 1 n (count (:abilities card))))
             (nth (:abilities card) (dec n)))]
    (when (and ab (= :act (:kind ab)) (not (board/stripped? g src)))
      ab)))

(defn check-activate
  "Validate ACT of object `src`, ability `n`, with `targets`.  Returns an
  error kind or nil."
  [g player src n targets]
  (let [o (board/obj g src)]
    (cond
      (not (and o (= :field (:zone o)) (= player (board/ctrl g src)))) :no-such-object
      :else
      (let [ab (activatable-ability g src n)]
        (cond
          (nil? ab) :no-such-ability
          (not= (count targets) (count (:targets ab))) :bad-target-count
          (or (not= (count targets) (count (set targets)))
              (not (every? true? (map #(tgt/legal-target? g %1 %2 player src nil)
                                      (:targets ab) targets))))
          :illegal-target
          (not (costs-payable? g player src ab)) :cost-unpayable
          :else nil)))))

(defn- pay-cost! [g player src n item]
  (case (first item)
    :ember (let [k (second item)]
             (st/update-pl! g player :ember - k)
             (when (pos? k) (emit! g "PAY" (name player) "ember" k)))
    :spire (let [k (second item)]
             (when (pos? k) (emit! g "PAY" (name player) "spire" k))
             (rules/change-spire! g player (- k)))
    :discard (dotimes [_ (second item)] (rules/discard-one! g player))
    :exhaust (rules/set-ready! g src false)
    :sacself (rules/sacrifice! g src)
    :counters (rules/adjust-counters! g src (- (second item)))
    :once (st/update-obj-key! g src :once conj n)))

(defn activate!
  "11.3: activate ability `n` of `src`; `check-activate` must have passed."
  [g player src n targets]
  (let [ab (activatable-ability g src n)
        cid (st/next-cid! g)]
    (st/upd! g update :chain conj
             {:cid cid :kind :ability :ctrl player :src src :idx n :targets (vec targets)
              :tspecs (vec (:targets ab)) :effects (:effects ab) :it nil})
    (apply emit! g "ACTIVATE" (name player) (render [:c cid]) (render src) n
           (map render targets))
    (doseq [item (:cost ab)]
      (pay-cost! g player src n item))))
