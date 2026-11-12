(ns cardgame.board
  "Cached access to derived characteristics, and evaluation contexts.

  [[derived]] returns the layer-system result for the current state, computing
  it at most once between state changes (every [[cardgame.state/upd!]]
  discards the cache).  The remaining functions are conveniences over it for
  the rules code: current controller, keywords, edge, core."
  (:require [cardgame.state :as st]
            [cardgame.layers :as layers]
            [cardgame.prng :as prng]))

(def ^:private verify-cache?
  "When the system property `cardgame.verify` is set, every cache hit is
  checked against a fresh derivation (used by the test-suite to validate the
  cache-invalidation rules of [[cardgame.state/upd-facets!]])."
  (some? (System/getProperty "cardgame.verify")))

(defn derived
  "The derived characteristics of the current state of `g`."
  [g]
  (let [s @g]
    (if-let [d (:derived s)]
      (do (when verify-cache?
            (let [fresh (layers/derive-board s)]
              (when-not (= fresh d)
                (throw (ex-info "stale derived characteristics" {:cached d :fresh fresh})))))
          d)
      (let [d (layers/derive-board s)]
        (swap! g assoc :derived d)
        d))))

(defn- rand! [g n]
  (let [[st' v] (prng/below (:rng @g) n)]
    (swap! g assoc :rng st')
    v))

(defn ctx
  "An evaluation context for the live state of `g`, extended with `m`."
  [g m]
  (assoc m :s @g :d (derived g) :rand (fn [n] (rand! g n))))

(defn obj [g oid] (st/obj @g oid))

(defn on-field? [g oid] (st/on-field? @g oid))

(defn ctrl
  "Current controller of `oid`: derived on the Field, otherwise the
  controller it had when it last left the Field (its owner if never)."
  [g oid]
  (let [o (st/obj @g oid)]
    (if (= :field (:zone o))
      (get-in (derived g) [:ctrl oid] (:ctrl o))
      (or (:last-ctrl o) (:owner o)))))

(defn kws
  "Current keyword instances of `oid` (printed keywords off the Field)."
  [g oid]
  (let [o (st/obj @g oid)]
    (if (= :field (:zone o))
      (get-in (derived g) [:kws oid] (:keywords (:def o)))
      (:keywords (:def o)))))

(defn has-kw? [g oid k]
  (boolean (some #(= k (:kw %)) (kws g oid))))

(defn plating
  "Sum of the values of every plating instance of `oid`."
  [g oid]
  (reduce + 0 (keep #(when (= "plating" (:kw %)) (:n %)) (kws g oid))))

(defn stripped? [g oid]
  (and (on-field? g oid) (contains? (:stripped (derived g)) oid)))

(defn edge [g oid]
  (let [o (st/obj @g oid)]
    (if (= :field (:zone o))
      (get-in (derived g) [:edge oid])
      (or (some-> o :def :body first) 0))))

(defn core [g oid]
  (let [o (st/obj @g oid)]
    (if (= :field (:zone o))
      (get-in (derived g) [:core oid])
      (or (some-> o :def :body second) 0))))

(defn unit? [g oid] (= :unit (:type (:def (st/obj @g oid)))))

(defn settling? [g oid]
  (let [s @g] (st/settling? s (st/obj s oid))))
