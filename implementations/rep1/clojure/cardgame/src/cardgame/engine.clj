(ns cardgame.engine
  "The resumable game engine: setup (SPEC 8), the turn structure (9),
  priority (10), and the handling of player actions (11, 19, 20, 24).

  A game is an atom (see [[cardgame.state]]).  [[new-game]] performs setup
  and runs forward to the first decision point; [[submit!]] validates one
  player action, applies it, and runs forward to the next decision point.
  Nothing is ever replayed: the engine keeps a program counter (`:pc`) in the
  state and resumes from it."
  (:require [cardgame.state :as st :refer [emit! render]]
            [cardgame.board :as board]
            [cardgame.prng :as prng]
            [cardgame.rules :as rules]
            [cardgame.chain :as chain]
            [cardgame.combat :as combat]
            [cardgame.triggers :as trig]))

;; ---------------------------------------------------------------------------
;; Guarding against the end of the match

(defn- match-over? [e] (= :match-over (:cardgame/error (ex-data e))))

(defmacro ^:private guarded
  "Evaluate body; the exception that ends the match is swallowed (the state
  already records the result)."
  [& body]
  `(try ~@body
        (catch clojure.lang.ExceptionInfo e#
          (when-not (match-over? e#) (throw e#)))))

;; ---------------------------------------------------------------------------
;; Turn structure

(def ^:private next-step
  {:dawn :draw, :draw :main1, :main1 :clash-attack, :clash-attack :clash-block,
   :clash-end :main2, :main2 :dusk-trigger, :dusk-trigger :dusk-discard,
   :dusk-discard :dusk-cleanup})

(defn- start-priority!
  "10.4: begin a priority round for the current step."
  [g]
  (let [step (:step @g)
        active (:active @g)]
    (st/upd! g assoc :pc [:prio step] :prio {:counter 0 :holder active}
             :decision [active :priority])
    (chain/settle! g)
    (st/upd! g assoc-in [:prio :holder] active)
    (st/upd! g assoc :decision [active :priority])))

(defn- do-dawn! [g]
  (let [active (:active @g)
        maxcap (get-in @g [:cfg :maxcap])]
    (st/update-pl! g active :cap (fn [c] (min (inc c) maxcap)))
    (doseq [p st/players]
      (st/upd! g assoc-in [:pl p :ember] (st/pl @g p :cap))
      (emit! g "EMBER" (name p) (st/pl @g p :ember) (st/pl @g p :cap)))
    (doseq [oid (st/field-oids @g)]
      (when (and (= active (board/ctrl g oid)) (not (:ready (st/obj @g oid))))
        (rules/set-ready! g oid true)))
    (doseq [oid (st/field-oids @g)]
      (st/set-obj! g oid :tenused false :once #{}))
    (trig/collect-from! g "turn-start" (fn [_ _] true) active)
    (trig/collect-from! g "your-turn-start" (fn [_ c] (= c active)) active)
    (let [{fire true held false} (group-by #(and (= :your-next-turn-start (:when %))
                                                 (= active (:ctrl %)))
                                           (:delayed @g))]
      (st/upd! g assoc :delayed (vec held))
      (doseq [d fire] (trig/collect-delayed! g d)))
    (chain/drain! g)))

(defn- do-draw! [g]
  (let [s @g]
    (when-not (and (= 1 (:turn s)) (= (:active s) (get-in s [:cfg :first])))
      (rules/draw-one! g (:active s) true))
    (chain/drain! g)))

(defn- do-dusk-trigger! [g]
  (let [active (:active @g)]
    (trig/collect-from! g "turn-end" (fn [_ _] true) active)
    (trig/collect-from! g "your-turn-end" (fn [_ c] (= c active)) active)
    (let [{fire true held false} (group-by #(= :turn-end (:when %)) (:delayed @g))]
      (st/upd! g assoc :delayed (vec held))
      (doseq [d fire] (trig/collect-delayed! g d)))))

(defn- do-dusk-discard! [g]
  (let [active (:active @g)
        limit (get-in @g [:cfg :handmax])]
    (while (> (st/hand-size @g active) limit)
      (rules/discard-one! g active))
    (chain/drain! g)))

(defn- do-dusk-cleanup! [g]
  (doseq [oid (st/field-oids @g)]
    (st/set-obj! g oid :wounds 0 :doomed false :ward 0))
  (st/upd! g (fn [s] (-> s (assoc-in [:pl :A :shield] 0) (assoc-in [:pl :B :shield] 0))))
  (let [turn (:turn @g)]
    (doseq [r (:records @g)
            :when (and (= :turn (:dur r)) (= :control (:kind r)))
            oid (:affected r)
            :when (st/on-field? @g oid)]
      (st/set-obj! g oid :since turn)))
  (st/upd! g update :records (fn [rs] (filterv #(not= :turn (:dur %)) rs)))
  (st/upd! g update :delayed (fn [ds] (filterv #(= :your-next-turn-start (:when %)) ds)))
  (chain/drain! g))

(defn- begin-turn! [g]
  (let [{:keys [turn active]} @g]
    (emit! g "TURN" turn (name active))
    (st/upd! g assoc :step :dawn :pc [:enter :dawn])))

(defn- advance-turn! [g]
  (let [s @g
        turn (inc (:turn s))]
    (st/upd! g assoc :turn turn :active (st/opp (:active s)))
    (if (> turn (get-in s [:cfg :turnlimit]))
      (rules/end-draw! g "turn-limit")
      (begin-turn! g))))

(defn- enter-step!
  "Enter `step`: emit its PHASE line, perform its turn-based actions and
  either stop at a decision point or move on."
  [g step]
  (st/upd! g assoc :step step)
  (emit! g "PHASE" (name step))
  (case step
    :dawn (do (do-dawn! g) (st/upd! g assoc :pc [:enter :draw]))
    :draw (do (do-draw! g) (st/upd! g assoc :pc [:enter :main1]))
    (:main1 :main2) (start-priority! g)
    :clash-attack (do (chain/settle! g)
                      (st/upd! g assoc :pc [:attackers] :decision [(:active @g) :attackers]))
    :clash-block (do (chain/settle! g)
                     (st/upd! g assoc :pc [:blockers]
                              :decision [(st/opp (:active @g)) :blockers]))
    :clash-riposte (let [riposters (filterv #(board/has-kw? g % "riposte") (combat/in-combat g))]
                     (st/upd! g assoc :riposters (set riposters))
                     (combat/deal-combat-damage! g riposters)
                     (start-priority! g))
    :clash-damage (let [done (:riposters @g)]
                    (combat/deal-combat-damage! g (remove done (combat/in-combat g)))
                    (start-priority! g))
    :clash-end (let [{fire true held false} (group-by #(= :end-of-combat (:when %)) (:delayed @g))]
                 (doseq [oid (combat/in-combat g)]
                   (trig/collect-self! g "end-of-combat" oid oid))
                 (st/upd! g assoc :delayed (vec held))
                 (doseq [d fire] (trig/collect-delayed! g d))
                 (start-priority! g))
    :dusk-trigger (do (do-dusk-trigger! g) (start-priority! g))
    :dusk-discard (do (do-dusk-discard! g) (st/upd! g assoc :pc [:enter :dusk-cleanup]))
    :dusk-cleanup (do (do-dusk-cleanup! g) (advance-turn! g))))

(defn- finish-step!
  "The priority round (or declaration) of the current step is over."
  [g]
  (let [step (:step @g)]
    (case step
      :clash-block
      (st/upd! g assoc :riposters #{} :pc
               [:enter (if (some #(board/has-kw? g % "riposte") (combat/in-combat g))
                         :clash-riposte
                         :clash-damage)])
      :clash-riposte (st/upd! g assoc :pc [:enter :clash-damage])
      :clash-damage (st/upd! g assoc :pc [:enter :clash-end])
      :clash-end (do (combat/clear-combat! g)
                     (st/upd! g assoc :pc [:enter :main2] :riposters #{}))
      (st/upd! g assoc :pc [:enter (next-step step)]))))

(defn- advance!
  "Run forward until a decision point is reached or the match ends."
  [g]
  (loop []
    (let [pc (:pc @g)]
      (when (= :enter (first pc))
        (enter-step! g (second pc))
        (recur)))))

;; ---------------------------------------------------------------------------
;; Setup

(defn- build-objects!
  "8 steps 4-6: create every setup object and place the Field ones."
  [g zones]
  (let [field-oids
        (reduce
         (fn [acc p]
           (reduce
            (fn [acc z]
              (reduce (fn [acc [cid n]]
                        (reduce (fn [acc _]
                                  (if (= z :field)
                                    (conj acc [p (st/new-object! g cid p :limbo)])
                                    (do (st/new-object! g cid p (if (= z :deck) :vault z)) acc)))
                                acc (range n)))
                      acc (get-in zones [p z])))
            acc [:deck :hand :field :ash :rift]))
         [] st/players)]
    (doseq [[p oid] field-oids]
      (rules/enter-field! g oid p true))))

(defn new-game
  "Create a game from `cfg` (see [[cardgame.matchfile/parse-setup]]) and card
  table `db`, perform setup and run to the first decision point.  Unknown
  card ids must have been rejected beforehand."
  [cfg db]
  (let [g (atom (st/initial-state cfg db))
        first-p (:first cfg)]
    (guarded
     (build-objects! g (:zones cfg))
     (swap! g assoc :rng (prng/make (:seed cfg)))
     (emit! g "GAME-START" (name first-p))
     (when (:shuffle cfg)
       (doseq [p st/players]
         (let [[rng' v] (prng/shuffle-vec (:rng @g) (vec (st/zone-of @g p :vault)))]
           (st/upd! g (fn [s] (-> s (assoc :rng rng')
                                  (assoc-in [:zones p :vault]
                                            (into clojure.lang.PersistentQueue/EMPTY v)))))
           (emit! g "SHUFFLE" (name p)))))
     (doseq [p [first-p (st/opp first-p)]]
       (rules/draw! g p (:opening cfg) false))
     (chain/settle! g)
     (begin-turn! g)
     (advance! g))
    g))

;; ---------------------------------------------------------------------------
;; Actions

(defn- action-kind [action]
  (case (:type action)
    (:pass :play :act) :priority
    :attack :attackers
    :block :blockers
    :concede nil))

(defn- pass! [g]
  (let [{:keys [prio chain]} @g
        player (first (:decision @g))]
    (emit! g "PASS" (name player))
    (let [counter (inc (:counter prio))]
      (cond
        (= 1 counter)
        (st/upd! g assoc :prio {:counter 1 :holder (st/opp player)}
                 :decision [(st/opp player) :priority])

        (seq chain)
        (do (st/upd! g assoc :prio {:counter 0 :holder player})
            (chain/resolve-top! g)
            (chain/settle! g)
            (st/upd! g assoc :prio {:counter 0 :holder (:active @g)}
                     :decision [(:active @g) :priority]))

        :else (finish-step! g)))))

(defn- after-acting!
  "10.4: after a PLAY/ACT by `player`: counter 0, actor holds priority, then
  settle; if settle acted the active player holds priority."
  [g player]
  (st/upd! g assoc :prio {:counter 0 :holder player} :decision [player :priority])
  (when (chain/settle! g)
    (st/upd! g assoc :prio {:counter 0 :holder (:active @g)}
             :decision [(:active @g) :priority])))

(defn- perform!
  "Check the action-specific conditions and perform `action`.  Returns an
  error kind or nil."
  [g player action]
  (case (:type action)
    :pass (do (pass! g) nil)

    :concede (do (rules/record-loss! g player "concede")
                 (rules/end-match! g))

    :play (or (chain/check-play g player (:pos action) (:targets action))
              (do (chain/play! g player (:pos action) (:targets action))
                  (after-acting! g player)
                  nil))

    :act (or (chain/check-activate g player (:oid action) (:index action) (:targets action))
             (do (chain/activate! g player (:oid action) (:index action) (:targets action))
                 (after-acting! g player)
                 nil))

    :attack (or (combat/check-attack g (:oids action))
                (if (empty? (:oids action))
                  (do (st/upd! g assoc :pc [:enter :main2]) nil)
                  (do (combat/declare-attackers! g (:oids action))
                      (start-priority! g)
                      nil)))

    :block (or (combat/check-block g (:pairs action))
               (do (combat/declare-blockers! g (:pairs action))
                   (start-priority! g)
                   nil))))

(defn submit!
  "Apply `action` from `player` to the game `g`.  Returns nil when the
  action was accepted, otherwise the error kind keyword (the game is
  unchanged).  Runs the engine forward to the next decision point."
  [g player action]
  (let [s @g]
    (cond
      (:over s) :game-over
      (not= player (first (:decision s))) :not-your-turn
      (and (action-kind action) (not= (action-kind action) (second (:decision s)))) :wrong-decision
      :else
      (let [err (volatile! nil)]
        (guarded
         (vreset! err (perform! g player action))
         (when-not @err (advance! g)))
        @err))))

(defn finish!
  "Emit the final `RESULT pending none` line if the match is still running."
  [g]
  (when-not (:over @g)
    (emit! g "RESULT" "pending" "none")))
