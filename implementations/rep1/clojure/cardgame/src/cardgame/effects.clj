(ns cardgame.effects
  "The effect interpreter (SPEC 6.8 - 6.9, 13.5, 14.1).

  [[run!]] executes a vector of compiled effects (see [[cardgame.cards]])
  against the game atom `g` under an *effect context*:

      {:ctrl P          ; the ability's controller
       :src oid         ; the source object
       :targets [tok]   ; the ability's targets
       :removed #{i}    ; indices of targets that became illegal
       :tspecs [spec]   ; the specifications the targets were checked against
       :it tok          ; the trigger subject, if any}

  Effects run in written order, each completely, with no state check between
  them."
  (:require [cardgame.state :as st :refer [emit! render]]
            [cardgame.board :as board]
            [cardgame.query :as q]
            [cardgame.rules :as rules]
            [cardgame.cards :as cards]))

(declare execute!)

(defn- qctx [g ctx] (board/ctx g ctx))

(defn- amt [g ctx a] (q/amount (qctx g ctx) a))
(defn- objs [g ctx sel] (q/objects (qctx g ctx) sel))
(defn- plrs [g ctx psel] (q/players (qctx g ctx) psel))

(defn- on-field-objs
  "Objects selected by `sel` that are on the Field (optionally only units)."
  [g ctx sel unit-only?]
  (filterv (fn [oid]
             (let [o (board/obj g oid)]
               (and (= :field (:zone o))
                    (or (not unit-only?) (= :unit (:type (:def o)))))))
           (objs g ctx sel)))

(defn create-record!
  "14.1: create a discrete (turn-duration) continuous-effect record over
  `affected` (oids on the Field, canonical order).  Returns the record."
  [g ctx kind args affected]
  (let [ts (st/next-ts! g)
        eid (st/next-eid! g)
        r {:eid eid :ts ts :ctrl (:ctrl ctx) :src (:src ctx) :kind kind :args args
           :dur :turn :affected (vec affected)}]
    (st/upd! g update :records conj r)
    r))

(defn- run-record-effect!
  "Shared body of modify, setbody, swapstats, grant, strip, control."
  [g ctx kind args sel emit-fn]
  (let [affected (on-field-objs g ctx sel false)]
    (create-record! g ctx kind args affected)
    (doseq [oid affected] (emit-fn oid))))

(defn- each-player [g ctx psel f]
  (doseq [p (plrs g ctx psel)] (f p)))

(defn- run-dig! [g ctx k filters psel]
  (doseq [p (plrs g ctx psel)]
    (let [taken (loop [i 0, acc []]
                  (if (< i k)
                    (if-let [oid (st/vault-pop! g p)] (recur (inc i) (conj acc oid)) acc)
                    acc))
          c (qctx g ctx)
          hit (first (filter #(q/filters-hold? c (st/obj @g %) filters) taken))]
      (if hit
        (let [o (st/obj @g hit)]
          (st/zone-append! g hit :hand)
          (emit! g "DIG" (name p) (render hit) (:cid o)))
        (emit! g "DIG-MISS" (name p)))
      (doseq [oid (remove #{hit} taken)]
        (st/upd! g update-in [:zones p :vault] conj oid)
        (emit! g "BOTTOM" (name p) (render oid) (:cid (st/obj @g oid)))))))

(defn- run-effect! [g ctx e]
  (case (first e)
    :nothing nil

    :damage
    (let [n (amt g ctx (nth e 1))]
      (when (pos? n)
        (doseq [tgt (q/damage-targets (qctx g ctx) (nth e 2))]
          (rules/deal-damage! g (:src ctx) tgt n))))

    :destroy
    (doseq [oid (objs g ctx (nth e 1))]
      (when (st/on-field? @g oid) (rules/destroy! g oid)))

    :sacrifice
    (doseq [oid (objs g ctx (nth e 1))]
      (when (st/on-field? @g oid) (rules/sacrifice! g oid)))

    :exile
    (doseq [oid (objs g ctx (nth e 1))]
      (rules/exile! g oid))

    :bounce
    (doseq [oid (objs g ctx (nth e 1))]
      (when (st/on-field? @g oid) (rules/bounce! g oid)))

    :draw
    (let [n (amt g ctx (nth e 1))]
      (when (pos? n) (each-player g ctx (nth e 2) #(rules/draw! g % n true))))

    :discard
    (let [n (amt g ctx (nth e 1))]
      (when (pos? n)
        (each-player g ctx (nth e 2) (fn [p] (dotimes [_ n] (rules/discard-one! g p))))))

    :mill
    (let [n (amt g ctx (nth e 1))]
      (when (pos? n)
        (each-player g ctx (nth e 2) (fn [p] (dotimes [_ n] (rules/mill-one! g p))))))

    :spire
    (let [n (amt g ctx (nth e 1))]
      (each-player g ctx (nth e 2) #(rules/change-spire! g % n)))

    :ember
    (let [n (amt g ctx (nth e 1))]
      (when (pos? n) (each-player g ctx (nth e 2) #(rules/gain-ember! g % n))))

    :cap
    (let [n (amt g ctx (nth e 1))]
      (when (pos? n) (each-player g ctx (nth e 2) #(rules/raise-cap! g % n))))

    :modify
    (let [a (amt g ctx (nth e 1)) b (amt g ctx (nth e 2))]
      (run-record-effect! g ctx :modify [a b] (nth e 3)
                          #(emit! g "BUFF" (render %) a b)))

    :setbody
    (let [a (amt g ctx (nth e 1)) b (amt g ctx (nth e 2))]
      (run-record-effect! g ctx :setbody [a b] (nth e 3)
                          #(emit! g "SETBODY" (render %) a b)))

    :swapstats
    (run-record-effect! g ctx :swapstats [] (nth e 1) #(emit! g "SWAP" (render %)))

    :grant
    (let [kw (nth e 1)]
      (run-record-effect! g ctx :grant [kw] (nth e 2)
                          #(emit! g "GRANT" (render %) (cards/render-kw kw))))

    :strip
    (run-record-effect! g ctx :strip [] (nth e 1) #(emit! g "STRIP" (render %)))

    :control
    (run-record-effect! g ctx :control [(:ctrl ctx)] (nth e 1)
                        (fn [oid]
                          (st/set-obj! g oid :since (:turn @g))
                          (rules/remove-from-combat! g oid)
                          (emit! g "CONTROL" (render oid) (name (:ctrl ctx)))))

    :counters
    (let [n (amt g ctx (nth e 1))]
      (doseq [oid (on-field-objs g ctx (nth e 2) false)]
        (rules/adjust-counters! g oid n)))

    :ready
    (doseq [oid (on-field-objs g ctx (nth e 1) false)]
      (rules/set-ready! g oid true))

    :exhaust
    (doseq [oid (on-field-objs g ctx (nth e 1) false)]
      (rules/set-ready! g oid false))

    :doom
    (doseq [oid (on-field-objs g ctx (nth e 1) true)]
      (rules/doom! g oid))

    :ward
    (let [n (amt g ctx (nth e 1))]
      (when (pos? n)
        (doseq [oid (on-field-objs g ctx (nth e 2) false)]
          (rules/add-ward! g oid n))))

    :shield
    (let [n (amt g ctx (nth e 1))]
      (when (pos? n) (each-player g ctx (nth e 2) #(rules/add-shield! g % n))))

    :summon
    (let [n (amt g ctx (nth e 2))]
      (when (pos? n)
        (each-player g ctx (nth e 3)
                     (fn [p] (dotimes [_ n] (rules/create-object! g (nth e 1) p :field))))))

    :conjure
    (let [n (amt g ctx (nth e 2))]
      (when (pos? n)
        (each-player g ctx (nth e 3)
                     (fn [p] (dotimes [_ n] (rules/create-object! g (nth e 1) p :hand))))))

    :reanimate
    (doseq [oid (objs g ctx (nth e 1))]
      (let [o (board/obj g oid)]
        (when (and (= :ash (:zone o)) (= :unit (:type (:def o))))
          (rules/reanimate! g oid (:ctrl ctx)))))

    :recall
    (doseq [oid (objs g ctx (nth e 1))]
      (when (= :ash (:zone (board/obj g oid)))
        (rules/recall! g oid)))

    :negate
    (let [t (q/target-token (qctx g ctx) (second (nth e 1)))]
      (when (vector? t)
        (rules/negate! g (second t))))

    :dig (run-dig! g ctx (nth e 1) (nth e 2) (nth e 3))

    :delay
    (let [w (nth e 1)
          d {:ts (st/next-ts! g) :ctrl (:ctrl ctx) :src (:src ctx) :when w
             :effects (nth e 2) :targets (:targets ctx) :tspecs (:tspecs ctx)}]
      (st/upd! g update :delayed conj d)
      (emit! g "DELAY" (name (:ctrl ctx)) (name w)))

    :if
    (if (q/condition (qctx g ctx) (nth e 1))
      (execute! g ctx (nth e 2))
      (execute! g ctx (nth e 3)))

    :each
    (let [lst (objs g ctx (nth e 1))
          zones (mapv #(:zone (board/obj g %)) lst)]
      (doseq [[oid z] (map vector lst zones)]
        (when (= z (:zone (board/obj g oid)))
          (execute! g (assoc ctx :that oid) (nth e 2)))))

    :repeat
    (let [n (amt g ctx (nth e 1))]
      (dotimes [_ (max 0 n)] (execute! g ctx (nth e 2))))))

(defn execute!
  "Execute the compiled `effects` under effect context `ctx`."
  [g ctx effects]
  (doseq [e effects]
    (run-effect! g ctx e)))
