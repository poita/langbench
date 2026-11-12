(ns cardgame.rules
  "The atomic state-changing procedures of SPEC section 17 (plus ending the
  match, section 20).

  Each procedure here is atomic in the sense of the specification: it emits
  its events and collects triggers, but never runs a state check or pushes
  triggers.  Procedures expect to be called with legal arguments (objects on
  the Field where the rule says so); the effect interpreter does the
  skipping of illegal ones."
  (:require [cardgame.state :as st :refer [emit! render]]
            [cardgame.board :as board]
            [cardgame.triggers :as trig]))

;; ---------------------------------------------------------------------------
;; Ending the match (section 20)

(defn record-loss!
  "Record that `p` has lost for `reason`, unless a loss is already recorded."
  [g p reason]
  (when-not (contains? (:loss @g) p)
    (st/upd! g assoc-in [:loss p] reason)))

(defn end-match!
  "End the match: emit `LOSE` lines for each loser and the `RESULT` line.
  Throws the match-over signal caught by the engine."
  [g]
  (let [loss (:loss @g)
        losers (filter loss st/players)
        winner (cond (= 2 (count losers)) "draw"
                     :else (name (st/opp (first losers))))
        reason (get loss (first losers))]
    (doseq [p losers] (emit! g "LOSE" (name p) (get loss p)))
    (emit! g "RESULT" winner reason)
    (st/upd! g assoc :over true :result [winner reason] :decision nil)
    (throw (ex-info "match over" {:cardgame/error :match-over}))))

(defn end-draw!
  "End the match in a draw for `reason` (the turn limit)."
  [g reason]
  (emit! g "RESULT" "draw" reason)
  (st/upd! g assoc :over true :result ["draw" reason] :decision nil)
  (throw (ex-info "match over" {:cardgame/error :match-over})))

;; ---------------------------------------------------------------------------
;; Players: spire, ember, cap, shield

(defn change-spire!
  "17.10: change `p`'s Spire by `n`."
  [g p n]
  (when-not (zero? n)
    (st/update-pl! g p :spire + n)
    (emit! g "SPIRE" (name p) (st/signed n) (st/pl @g p :spire))
    (when (neg? n) (trig/collect-spire-loss! g p))))

(defn gain-ember! [g p n]
  (when (pos? n)
    (st/update-pl! g p :ember + n)
    (emit! g "EMBERGAIN" (name p) n (st/pl @g p :ember))))

(defn raise-cap! [g p n]
  (when (pos? n)
    (st/update-pl! g p :cap (fn [c] (min (+ c n) (get-in @g [:cfg :maxcap]))))
    (emit! g "CAP" (name p) n (st/pl @g p :cap))))

(defn add-shield! [g p n]
  (when (pos? n)
    (st/update-pl! g p :shield + n)
    (emit! g "SHIELD" (name p) n (st/pl @g p :shield))))

;; ---------------------------------------------------------------------------
;; Leaving and entering the Field

(defn remove-from-combat!
  "7.5: keep the combat status of other objects consistent when `oid` stops
  being in combat."
  [g oid]
  (let [o (st/obj @g oid)]
    (when-let [a (:blocking o)]
      (st/update-obj-key! g a :blockers (fn [bs] (filterv #(not= % oid) bs)))
      (st/set-obj! g oid :blocking nil))
    (when (:attacking o)
      (doseq [b (:blockers o)]
        (when (= oid (:blocking (st/obj @g b)))
          (st/set-obj! g b :blocking nil)))
      (st/set-obj! g oid :attacking false :blockers [] :blocked false))))

(defn- leave-field!
  "Take `oid` off the Field into `zone` (:ash, :rift or :hand), emitting
  nothing.  Returns the controller it had.  The caller emits the event; this
  performs 17.3 step 4 afterwards via [[finish-leaving!]]."
  [g oid zone]
  (let [ctrl (board/ctrl g oid)
        o (st/obj @g oid)]
    (remove-from-combat! g oid)
    (st/upd! g update :field disj [(:ts o) oid])
    (st/zone-append! g oid zone)
    ctrl))

(defn- finish-leaving!
  "17.3 step 4: drop the aura records and the Field state."
  [g oid ctrl]
  (st/upd! g update :records
           (fn [rs] (filterv #(not (and (= :aura (:dur %)) (= oid (:src %)))) rs)))
  (st/update-obj! g oid (fn [o] (assoc (st/clear-field-state o) :last-ctrl ctrl))))

(defn- die!
  "Common part of destroy and sacrifice; `ename` is the event name."
  [g oid ename]
  (let [cid (:cid (st/obj @g oid))
        ctrl (leave-field! g oid :ash)]
    (emit! g ename (render oid) cid)
    (finish-leaving! g oid ctrl)
    (trig/collect-departed! g "dies" oid ctrl)
    (trig/collect-departed! g "leave" oid ctrl)
    (trig/collect-deaths! g oid ctrl)))

(defn destroy!
  "17.3: destroy `oid` (on the Field), subject to `tenacity`."
  [g oid]
  (let [o (st/obj @g oid)]
    (if (and (board/has-kw? g oid "tenacity") (not (:tenused o)))
      (do (st/set-obj! g oid :tenused true :wounds 0 :doomed false)
          (emit! g "TENACITY" (render oid)))
      (die! g oid "DESTROY"))))

(defn sacrifice! [g oid] (die! g oid "SACRIFICE"))

(defn exile!
  "17.5: move `oid` from wherever it is to its owner's Rift."
  [g oid]
  (let [o (st/obj @g oid)
        z (:zone o)]
    (case z
      :field (let [ctrl (leave-field! g oid :rift)]
               (emit! g "EXILE" (render oid) (:cid o) "field")
               (finish-leaving! g oid ctrl)
               (trig/collect-departed! g "leave" oid ctrl))
      (:hand :ash :vault :rift)
      (do (st/zone-remove! g oid)
          (st/zone-append! g oid :rift)
          (emit! g "EXILE" (render oid) (:cid o) (name z)))
      nil)))

(defn bounce!
  "17.6: move the Field object `oid` to the end of its owner's hand."
  [g oid]
  (let [o (st/obj @g oid)
        ctrl (leave-field! g oid :hand)]
    (emit! g "BOUNCE" (render oid) (:cid o))
    (finish-leaving! g oid ctrl)
    (trig/collect-departed! g "leave" oid ctrl)))

(defn create-aura-records!
  "14.2: one aura record per `aura` clause of the card of `oid`."
  [g oid]
  (doseq [a (:auras (:def (st/obj @g oid)))]
    (let [ts (st/next-ts! g)
          eid (st/next-eid! g)]
      (st/upd! g update :records conj
               {:eid eid :ts ts :dur :aura :kind :aura :src oid :ab (:n a)}))))

(defn enter-field!
  "17.17: put `oid` on the Field under base controller `ctrl`.  With
  `silent?` (setup) no event is emitted and no trigger collected."
  ([g oid ctrl] (enter-field! g oid ctrl false))
  ([g oid ctrl silent?]
   (st/zone-remove! g oid)
   (let [ts (st/next-ts! g)
         turn (if silent? 0 (:turn @g))]
     (st/upd! g (fn [s]
                  (-> s
                      (update-in [:objs oid]
                                 (fn [o] (-> o
                                             (st/fresh-field-state ctrl turn)
                                             (assoc :zone :field :ts ts))))
                      (update :field conj [ts oid]))))
     (create-aura-records! g oid)
     (when-not silent?
       (emit! g "ARRIVE" (render oid) (:cid (st/obj @g oid)))
       (trig/collect-arrival! g oid)))))

(defn create-object!
  "17.17: create a new object of card `cid` for `owner`; `zone` is `:field`
  or `:hand`.  Emits `CREATE`; a Field object then enters the Field."
  [g cid owner zone]
  (let [oid (st/new-object! g cid owner (if (= zone :hand) :hand :limbo))]
    (emit! g "CREATE" (render oid) cid (name zone))
    (when (= zone :field)
      (enter-field! g oid owner))
    oid))

(defn reanimate!
  "17.18: bring the Ash unit `oid` to the Field under `ctrl`."
  [g oid ctrl]
  (enter-field! g oid ctrl))

(defn recall!
  "17.19: move the Ash card `oid` to its owner's hand."
  [g oid]
  (let [o (st/obj @g oid)]
    (st/zone-remove! g oid)
    (st/zone-append! g oid :hand)
    (emit! g "RECALL" (render oid) (:cid o))))

;; ---------------------------------------------------------------------------
;; Damage (17.1, 15.2)

(defn deal-damage!
  "17.1: deal `n` damage from object `src` to token `tgt`."
  [g src tgt n]
  (when (pos? n)
    (let [obj-target? (integer? tgt)
          o (when obj-target? (st/obj @g tgt))]
      (when (or (not obj-target?)
                (and (= :field (:zone o)) (= :unit (:type (:def o)))))
        (let [p (if obj-target? (board/plating g tgt) 0)
              rem (max 0 (- n p))
              q (if obj-target? (:ward o) (st/pl @g tgt :shield))
              u (min q rem)
              m (- rem u)]
          (when (pos? u)
            (if obj-target?
              (st/update-obj-key! g tgt :ward - u)
              (st/update-pl! g tgt :shield - u)))
          (when (< m n)
            (emit! g "PREVENT" (render tgt) (- n m)))
          (when (pos? m)
            (emit! g "DAMAGE" (render src) (render tgt) m)
            (if obj-target?
              (st/update-obj-key! g tgt :wounds + m)
              (do (st/update-pl! g tgt :spire - m)
                  (emit! g "SPIRE" (name tgt) (str "-" m) (st/pl @g tgt :spire))
                  (trig/collect-spire-loss! g tgt)))
            (let [s-obj (st/obj @g src)
                  s-unit-on-field? (and (= :field (:zone s-obj)) (= :unit (:type (:def s-obj))))]
              (when (and obj-target? s-unit-on-field? (board/has-kw? g src "venom"))
                (st/set-obj! g tgt :doomed true)
                (emit! g "DOOM" (render tgt)))
              (when (and s-unit-on-field? (board/has-kw? g src "siphon"))
                (let [c (board/ctrl g src)]
                  (st/update-pl! g c :spire + m)
                  (emit! g "SPIRE" (name c) (str "+" m) (st/pl @g c :spire)))))
            (when obj-target?
              (trig/collect-self! g "damaged" tgt src))
            (when (st/on-field? @g src)
              (trig/collect-self! g "deals-damage" src tgt))))))))

;; ---------------------------------------------------------------------------
;; Cards moving between zones

(defn record-vault-loss! [g p] (record-loss! g p "vault"))

(defn draw-one!
  "17.7: make `p` draw one card.  Returns true if a card was drawn, false
  when the Vault was empty.  `triggers?` is false for the opening draws."
  [g p triggers?]
  (if-let [oid (st/vault-pop! g p)]
    (let [o (st/obj @g oid)]
      (st/zone-append! g oid :hand)
      (emit! g "DRAW" (name p) (render oid) (:cid o))
      (when triggers?
        (trig/collect-from! g "you-draw" (fn [_ c] (= c p)) oid))
      true)
    (do (emit! g "DRAW-EMPTY" (name p))
        (record-vault-loss! g p)
        false)))

(defn draw!
  "Make `p` draw `n` cards, stopping at the first empty Vault."
  [g p n triggers?]
  (loop [i 0]
    (when (< i n)
      (when (draw-one! g p triggers?)
        (recur (inc i))))))

(defn discard-one!
  "17.8: discard the card at hand position 1 of `p`."
  [g p]
  (when-let [oid (first (st/zone-of @g p :hand))]
    (let [o (st/obj @g oid)]
      (st/zone-remove! g oid)
      (st/zone-append! g oid :ash)
      (emit! g "DISCARD" (name p) (render oid) (:cid o)))))

(defn mill-one!
  "17.9: move the top Vault card of `p` to the Ash."
  [g p]
  (when-let [oid (st/vault-pop! g p)]
    (st/set-obj! g oid :zone :limbo)
    (st/zone-append! g oid :ash)
    (emit! g "MILL" (name p) (render oid) (:cid (st/obj @g oid)))))

;; ---------------------------------------------------------------------------
;; Per-object state

(defn adjust-counters!
  "17.14: add `n` charge counters to Field object `oid`, floored at zero."
  [g oid n]
  (let [old (:counters (st/obj @g oid))
        new (max 0 (+ old n))]
    (when (not= old new)
      (st/set-obj! g oid :counters new)
      (emit! g "COUNTERS" (render oid) (st/signed (- new old)) new))))

(defn set-ready!
  "17.15: make Field object `oid` ready (`ready?` true) or exhausted."
  [g oid ready?]
  (when (not= (boolean (:ready (st/obj @g oid))) ready?)
    (st/set-obj! g oid :ready ready?)
    (emit! g (if ready? "READY" "EXHAUST") (render oid))))

(defn doom!
  "17.16"
  [g oid]
  (st/set-obj! g oid :doomed true)
  (emit! g "DOOM" (render oid)))

(defn add-ward! [g oid n]
  (when (pos? n)
    (st/update-obj-key! g oid :ward + n)
    (emit! g "WARD" (render oid) n (:ward (st/obj @g oid)))))

;; ---------------------------------------------------------------------------
;; The Chain

(defn negate!
  "17.20: remove Chain entry `cid` from the Chain.  A played card goes to its
  owner's Ash."
  [g cid]
  (when-let [e (some #(when (= cid (:cid %)) %) (:chain @g))]
    (st/upd! g update :chain (fn [c] (filterv #(not= cid (:cid %)) c)))
    (emit! g "NEGATE" (render [:c cid]))
    (when (#{:rite :unit :relic} (:kind e))
      (let [o (st/obj @g (:src e))]
        (st/zone-append! g (:src e) :ash)
        (emit! g "SPENT" (render (:src e)) (:cid o))))))
