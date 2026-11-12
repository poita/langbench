(ns cardgame.inspect
  "Inspection blocks (SPEC section 23) and the legal-action enumerator
  (section 21).  Everything here is read-only: it never changes the game."
  (:require [clojure.string :as str]
            [cardgame.state :as st :refer [render]]
            [cardgame.board :as board]
            [cardgame.cards :as cards]
            [cardgame.chain :as chain]
            [cardgame.combat :as combat]
            [cardgame.targeting :as tgt]))

;; ---------------------------------------------------------------------------
;; LEGAL

(defn legal-lines
  "The action lines of `LEGAL` for the current decision point (21)."
  [g]
  (let [s @g
        [p kind] (:decision s)]
    (case kind
      :priority
      (concat
       ["PASS"]
       (for [[i oid] (map-indexed vector (st/zone-of s p :hand))
             :let [card (:def (st/obj s oid))]
             :when (and (chain/play-timing-ok? g p oid)
                        (<= (chain/play-cost g p oid) (st/pl s p :ember)))
             t (tgt/tuples g (chain/card-tspecs card) p oid nil)]
         (str/join " " (concat ["PLAY" (inc i) (:id card)] (map render t))))
       (for [oid (sort (filter #(= p (board/ctrl g %)) (st/field-oids s)))
             ab (:abilities (:def (st/obj s oid)))
             :when (chain/activatable-ability g oid (:n ab))
             :when (chain/costs-payable? g p oid ab)
             t (tgt/tuples g (:targets ab) p oid nil)]
         (str/join " " (concat ["ACT" (render oid) (:n ab)] (map render t)))))

      :attackers
      (let [cs (combat/attackable-units g)]
        (concat (map #(str "CANATTACK " (render %)) cs)
                (for [c cs :when (board/has-kw? g c "relentless")]
                  (str "MUSTATTACK " (render c)))))

      :blockers
      (let [defenders (sort (filter #(= p (board/ctrl g %)) (st/field-oids s)))
            atts (combat/attackers g)]
        (concat (for [b defenders, a atts :when (combat/can-block? g b a)]
                  (str "CANBLOCK " (render b) " " (render a)))
                (for [a atts :when (board/has-kw? g a "provoke")]
                  (str "MUSTBLOCK " (render a)))))

      [])))

(defn legal-block [g]
  (let [[p kind] (:decision @g)]
    (concat [(if p (str "LEGAL BEGIN " (name p) " " (name kind)) "LEGAL BEGIN - over")]
            (when p (legal-lines g))
            ["LEGAL END"])))

;; ---------------------------------------------------------------------------
;; VAULT, CARD

(defn vault-block [g]
  (let [s @g]
    (concat ["VAULT BEGIN"]
            (for [p st/players
                  [i oid] (map-indexed vector (st/zone-of s p :vault))]
              (str "vault " (name p) " " (inc i) " " (render oid) " " (:cid (st/obj s oid))))
            ["VAULT END"])))

(defn card-block [g id]
  (cards/render-card id (get (:db @g) id)))

;; ---------------------------------------------------------------------------
;; DUMP

(defn- flags [s o d oid]
  (let [fs (cond-> []
             (:attacking o) (conj "attacking")
             (:blocked o) (conj "blocked")
             (:blocking o) (conj "blocking")
             (:doomed o) (conj "doomed")
             (st/settling? s o) (conj "settling")
             (:tenused o) (conj "tenacity-used")
             (pos? (:ward o)) (conj (str "ward" (:ward o))))
        fs (into fs (map #(str "once" %) (:once o)))]
    (if (empty? fs) "-" (str/join "," (sort fs)))))

(defn- kwlist [d oid]
  (let [ks (get-in d [:kws oid])
        plating (reduce + 0 (keep #(when (= "plating" (:kw %)) (:n %)) ks))
        names (cond-> (set (map :kw (remove #(= "plating" (:kw %)) ks)))
                (some #(= "plating" (:kw %)) ks) (conj (str "plating:" plating)))]
    (if (empty? names) "-" (str/join "," (sort names)))))

(defn- field-line [s d p oid]
  (let [o (st/obj s oid)
        unit? (= :unit (:type (:def o)))]
    (str "field " (name p) " " (render oid) " " (:cid o) " "
         (if unit? (str (get-in d [:edge oid]) "/" (get-in d [:core oid])) "-/-")
         " w" (:wounds o) " c" (:counters o) " "
         (if (:ready o) "ready" "exhausted") " "
         (flags s o d oid) " kw " (kwlist d oid))))

(defn- objs-str [oids] (if (seq oids) (str/join "," (map render oids)) "-"))

(defn- effect-line [s d r]
  (if (= :aura (:dur r))
    (let [a (get (:auras d) (:eid r))
          l (first (:leaves a))]
      (when l
        (str "effect " (:eid r) " ts" (:ts r) " " (name (:ctrl a)) " aura " (:desc l)
             " on " (objs-str (:objs l)))))
    (let [desc (case (:kind r)
                 :modify (str "modify " (first (:args r)) " " (second (:args r)))
                 :setbody (str "setbody " (first (:args r)) " " (second (:args r)))
                 :swapstats "swapstats"
                 :grant (str "grant " (cards/render-kw (first (:args r))))
                 :strip "strip"
                 :control (str "control " (name (:ctrl r))))
          objs (filterv #(st/on-field? s %) (:affected r))]
      (str "effect " (:eid r) " ts" (:ts r) " " (name (:ctrl r)) " turn " desc
           " on " (objs-str objs)))))

(defn dump-block [g]
  (let [s @g
        d (board/derived g)
        [dp dk] (:decision s)]
    (concat
     ["STATE BEGIN"
      (str "turn " (:turn s) " active " (name (:active s)) " phase " (name (:step s))
           " decision " (if dp (str (name dp) " " (name dk)) "- over"))]
     (when (:over s) [(str "result " (first (:result s)) " " (second (:result s)))])
     (for [p st/players]
       (str "player " (name p) " spire " (st/pl s p :spire) " ember " (st/pl s p :ember)
            " cap " (st/pl s p :cap) " vault " (st/vault-size s p) " hand " (st/hand-size s p)
            " ash " (st/ash-size s p) " rift " (count (st/zone-of s p :rift))))
     (for [p st/players, [i oid] (map-indexed vector (st/zone-of s p :hand))]
       (str "hand " (name p) " " (inc i) " " (render oid) " " (:cid (st/obj s oid))))
     (for [p st/players
           oid (st/field-oids s)
           :when (= p (get-in d [:ctrl oid]))]
       (field-line s d p oid))
     (for [z [:ash :rift]
           p st/players
           [i oid] (map-indexed vector (st/zone-of s p z))]
       (str (name z) " " (name p) " " (inc i) " " (render oid) " " (:cid (st/obj s oid))))
     (for [[i e] (map-indexed vector (:chain s))]
       (str/join " " (concat ["chain" (inc i) (render [:c (:cid e)]) (name (:ctrl e))
                              (name (:kind e)) (render (:src e)) (:idx e)]
                             (map render (:targets e)))))
     (keep #(effect-line s d %) (:records s))
     (for [x (sort-by :ts (:delayed s))]
       (str/join " " (concat ["delayed" (:ts x) (name (:ctrl x)) (name (:when x))]
                             (map render (:targets x)))))
     ["STATE END"])))
