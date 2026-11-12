(ns cardgame.combat
  "Combat (SPEC section 19): attack and block legality, declarations and
  combat damage."
  (:require [cardgame.state :as st :refer [emit! render]]
            [cardgame.board :as board]
            [cardgame.rules :as rules]
            [cardgame.triggers :as trig]))

(defn can-attack?
  "19.2: can the object `oid` be declared as an attacker now?"
  [g oid]
  (let [s @g
        o (and (integer? oid) (st/obj s oid))]
    (boolean
     (and o
          (= :field (:zone o))
          (= (:active s) (board/ctrl g oid))
          (= :unit (:type (:def o)))
          (:ready o)
          (or (not (st/settling? s o)) (board/has-kw? g oid "vanguard"))
          (not (board/has-kw? g oid "shackled"))))))

(defn attackable-units
  "Every unit that can attack, in ascending oid order."
  [g]
  (filterv #(can-attack? g %) (sort (st/field-oids @g))))

(defn can-block?
  "19.4: can `b` block attacker `a`?"
  [g b a]
  (let [s @g
        ob (and (integer? b) (st/obj s b))
        oa (and (integer? a) (st/obj s a))]
    (boolean
     (and ob oa
          (= :field (:zone ob))
          (= (st/opp (:active s)) (board/ctrl g b))
          (= :unit (:type (:def ob)))
          (:ready ob)
          (not (board/has-kw? g b "siegework"))
          (= :field (:zone oa))
          (:attacking oa)
          (or (not (board/has-kw? g a "ghostwalk"))
              (board/has-kw? g b "ghostwalk")
              (board/has-kw? g b "skyhook"))))))

(defn attackers
  "Objects currently attacking, ascending oid."
  [g]
  (filterv #(:attacking (st/obj @g %)) (sort (st/field-oids @g))))

(defn in-combat
  "Units on the Field that are attacking or blocking, ascending oid."
  [g]
  (filterv #(let [o (st/obj @g %)] (or (:attacking o) (:blocking o)))
           (sort (st/field-oids @g))))

(defn blockers-needed?
  "19.4: is provoke violated by blocking with `pairs` (`[b a]` vectors)?"
  [g pairs]
  (let [used (set (map first pairs))
        blocked (set (map second pairs))
        defenders (filterv #(= (st/opp (:active @g)) (board/ctrl g %)) (sort (st/field-oids @g)))]
    (boolean
     (some (fn [a]
             (and (board/has-kw? g a "provoke")
                  (not (contains? blocked a))
                  (some (fn [b] (and (not (contains? used b)) (can-block? g b a))) defenders)))
           (attackers g)))))

(defn check-attack
  "Validate an ATTACK of `oids`; returns an error kind or nil."
  [g oids]
  (cond
    (not= (count oids) (count (set oids))) :duplicate-attacker
    (not (every? #(can-attack? g %) oids)) :illegal-attacker
    (some #(and (board/has-kw? g % "relentless") (not (contains? (set oids) %)))
          (attackable-units g))
    :missing-required-attacker
    :else nil))

(defn check-block
  "Validate a BLOCK of `pairs`; returns an error kind or nil."
  [g pairs]
  (let [bs (map first pairs)]
    (cond
      (not= (count bs) (count (set bs))) :duplicate-blocker
      (not (every? (fn [[b a]] (can-block? g b a)) pairs)) :illegal-blocker
      (blockers-needed? g pairs) :missing-required-block
      :else nil)))

(defn declare-attackers!
  "19.1: declare the (non-empty) set `oids` as attackers."
  [g oids]
  (let [oids (sort oids)]
    (doseq [oid oids]
      (st/set-obj! g oid :attacking true)
      (when-not (board/has-kw? g oid "vigil")
        (rules/set-ready! g oid false))
      (emit! g "ATTACK" (render oid)))
    (doseq [oid oids]
      (trig/collect-self! g "attacks" oid oid))))

(defn declare-blockers!
  "19.3: declare blockers from `pairs` of `[blocker attacker]`."
  [g pairs]
  (let [pairs (sort-by first pairs)]
    (doseq [[b a] pairs]
      (st/set-obj! g b :blocking a)
      (st/set-obj! g a :blocked true
                   :blockers (vec (st/canonical @g (conj (:blockers (st/obj @g a)) b))))
      (emit! g "BLOCK" (render b) (render a)))
    (let [unblocked (filterv #(empty? (:blockers (st/obj @g %))) (attackers g))]
      (doseq [a unblocked] (emit! g "UNBLOCKED" (render a)))
      (doseq [[b a] pairs] (trig/collect-self! g "blocks" b a))
      (doseq [a (sort (distinct (map second pairs)))]
        (when-let [first-b (first (:blockers (st/obj @g a)))]
          (trig/collect-self! g "blocked" a first-b)))
      (doseq [a unblocked] (trig/collect-self! g "unblocked" a a)))))

(defn- assignments
  "19.6: the `[source target amount]` triples unit `u` assigns."
  [g u]
  (let [s @g
        o (st/obj s u)
        e (board/edge g u)]
    (if (<= e 0)
      []
      (cond
        (:blocking o)
        [[u (:blocking o) e]]

        (not (:blocked o))
        [[u (st/opp (:active s)) e]]

        :else
        (let [venom? (board/has-kw? g u "venom")
              lst (filterv (fn [b] (let [ob (st/obj s b)]
                                     (and (= :field (:zone ob)) (= u (:blocking ob)))))
                           (:blockers o))]
          (if (empty? lst)
            []
            (let [[r acc]
                  (reduce (fn [[r acc] b]
                            (let [need (if venom? 1
                                           (max 0 (- (board/core g b) (:wounds (st/obj s b)))))
                                  k (min r need)]
                              [(- r k) (conj acc [u b k])]))
                          [e []] lst)]
              (if (pos? r)
                (if (board/has-kw? g u "pierce")
                  (conj acc [u (st/opp (:active s)) r])
                  (update acc (dec (count acc)) (fn [[a b k]] [a b (+ k r)])))
                acc))))))))

(defn deal-combat-damage!
  "19.5 - 19.6: simultaneous combat damage from `units`."
  [g units]
  (let [triples (->> (mapcat #(assignments g %) units)
                     (filter (fn [[_ _ n]] (pos? n)))
                     (sort-by (fn [[u t _]] [(st/token-key @g u) (st/token-key @g t)])))]
    (doseq [[u t n] triples]
      (rules/deal-damage! g u t n))))

(defn clear-combat!
  "19.7: clear every object's combat fields."
  [g]
  (doseq [oid (st/field-oids @g)]
    (let [o (st/obj @g oid)]
      (when (or (:attacking o) (:blocking o) (:blocked o) (seq (:blockers o)))
        (st/set-obj! g oid :attacking false :blocking nil :blocked false :blockers [])))))
