(ns cardgame.state
  "Game state: the shape of the state map, pure accessors over it, and the
  primitive mutators (object creation, zone movement, counters, event
  output) that every other game namespace builds on.

  The game is held in an atom (`g`) whose value is a persistent map.  Pure
  accessors take the *value* `s`; mutators take the atom `g` and, by
  convention, end in `!`.  Mutators discard the cached
  derived-characteristics value (see [[cardgame.board]]) unless the change
  provably cannot affect it ([[upd-facets!]]).")

;; ---------------------------------------------------------------------------
;; Players and tokens

(def players [:A :B])

(defn opp
  "The opponent of player `p`."
  [p]
  (if (= p :A) :B :A))

(defn render
  "Render a target token: a player `A`/`B`, an object `#7` or a Chain entry
  `~3`.  Tokens are `:A`, `:B`, an oid (long) or `[:c cid]`."
  [tok]
  (cond
    (keyword? tok) (name tok)
    (integer? tok) (str "#" tok)
    (vector? tok)  (str "~" (second tok))
    :else (str tok)))

;; ---------------------------------------------------------------------------
;; Construction

(defn empty-zones []
  {:vault clojure.lang.PersistentQueue/EMPTY :hand [] :ash [] :rift []})

(defn initial-state
  "A fresh state map for configuration `cfg` and card table `db`."
  [cfg db]
  {:db db
   :cfg cfg
   :objs {}
   :next-oid 1 :next-cid 1 :next-ts 1 :next-eid 1 :seq 0
   :zones {:A (empty-zones) :B (empty-zones)}
   :field (sorted-set)
   :pl (let [p (fn [x] {:spire (:spire cfg) :ember 0 :cap (get (:caps cfg) x 0) :shield 0})]
         {:A (p :A) :B (p :B)})
   :chain []
   :pending []
   :records []
   :delayed []
   :turn 1
   :active (:first cfg)
   :step :dawn
   :pc nil
   :prio nil
   :decision nil
   :riposters #{}
   :loss {}
   :result nil
   :over false
   :rng 0
   :out (StringBuilder.)})

;; ---------------------------------------------------------------------------
;; Pure accessors

(defn obj [s oid] (get (:objs s) oid))
(defn on-field? [s oid] (= :field (:zone (obj s oid))))
(defn card-of [s oid] (:def (obj s oid)))
(defn field-oids
  "Oids of every object on the Field in canonical (timestamp, oid) order."
  [s]
  (map second (:field s)))
(defn ctl-base [s oid] (:ctrl (obj s oid)))
(defn zone-of [s p z] (get-in s [:zones p z]))
(defn vault-size [s p] (count (zone-of s p :vault)))
(defn hand-size [s p] (count (zone-of s p :hand)))
(defn ash-size [s p] (count (zone-of s p :ash)))
(defn pl [s p k] (get-in s [:pl p k]))
(defn over? [s] (:over s))
(defn settling?
  "True when the Field object `o` is Settling (16.1)."
  [s o]
  (and (= :field (:zone o)) (>= (:since o) (:turn s))))

(defn canonical
  "Sort oids of `s` in canonical object order: ascending (timestamp, oid)."
  [s oids]
  (let [objs (:objs s)]
    (sort-by (fn [oid] [(:ts (get objs oid)) oid]) oids)))

(defn token-key
  "The target key of a token (12.4)."
  [s tok]
  (cond
    (= tok :A) [0 0 0]
    (= tok :B) [0 1 0]
    (integer? tok) [1 (:ts (obj s tok)) tok]
    :else [2 (second tok) 0]))

;; ---------------------------------------------------------------------------
;; Mutators

(def ^:private derivation-inputs
  "The parts of the state that characteristic derivation reads."
  [:objs :zones :field :pl :records :turn :active])

(defn upd!
  "Apply `(f state & args)` to the game.  The cached derived characteristics
  are discarded unless `f` left every input of the derivation untouched."
  [g f & args]
  (swap! g (fn [s]
             (let [s' (apply f s args)]
               (if (and (:derived s')
                        (every? #(identical? (get s %) (get s' %)) derivation-inputs))
                 s'
                 (dissoc s' :derived)))))
  nil)

(defn upd-facets!
  "Apply `(f state & args)`, a change touching only the given *facets* of
  the state.  Facets are keywords naming the optional inputs of derivation
  (`:wounds :ready :since :combat :hand :ash :vault :rift :spire :ember`);
  the derived cache survives unless an aura currently reads one of them.
  The empty set means a change derivation never reads."
  [g facets f & args]
  (swap! g (fn [s]
             (let [s' (apply f s args)
                   d (:derived s')]
               (if (and d (not-any? (:reads d) facets))
                 s'
                 (dissoc s' :derived)))))
  nil)

(def ^:private key-facets
  {:wounds #{:wounds} :ready #{:ready} :since #{:since}
   :attacking #{:combat} :blocking #{:combat}
   :ward #{} :tenused #{} :once #{} :doomed #{} :blockers #{} :blocked #{}
   :last-ctrl #{}})

(defn- facets-of [k]
  (get key-facets k #{}))

(defn next-ts!
  "Take a fresh timestamp."
  [g]
  (let [t (:next-ts @g)] (swap! g update :next-ts inc) t))

(defn next-cid! [g]
  (let [t (:next-cid @g)] (swap! g update :next-cid inc) t))

(defn next-eid! [g]
  (let [t (:next-eid @g)] (swap! g update :next-eid inc) t))

(defn update-obj!
  "Apply `(f obj & args)` to the object with id `oid` (a change of
  structural fields: invalidates derived characteristics)."
  [g oid f & args]
  (upd! g (fn [s] (update-in s [:objs oid] #(apply f % args)))))

(defn set-obj!
  "Associate `k`/`v` pairs on the object `oid`.  Keys that derivation reads
  only optionally (see [[upd-facets!]]) do not discard the derived cache
  unless an aura reads them; any other key does."
  [g oid & kvs]
  (let [ks (take-nth 2 kvs)]
    (if (every? key-facets ks)
      (apply upd-facets! g (into #{} (mapcat facets-of) ks)
             (fn [s] (update-in s [:objs oid] #(apply assoc % kvs))) [])
      (upd! g (fn [s] (update-in s [:objs oid] #(apply assoc % kvs)))))))

(defn update-obj-key!
  "Apply `(f (get obj k) & args)` to the single field `k` of object `oid`."
  [g oid k f & args]
  (let [fn' (fn [s] (update-in s [:objs oid k] #(apply f % args)))]
    (if (contains? key-facets k)
      (upd-facets! g (facets-of k) fn')
      (upd! g fn'))))

(def ^:private pl-facets {:spire #{:spire} :ember #{:ember} :cap #{} :shield #{}})

(defn update-pl!
  "Apply `(f value & args)` to key `k` of player `p`."
  [g p k f & args]
  (upd-facets! g (get pl-facets k #{:always})
               (fn [s] (update-in s [:pl p k] #(apply f % args)))))

(defn emit-raw!
  "Append a line that is not an event (no sequence number)."
  [g line]
  (let [^StringBuilder sb (:out @g)]
    (.append sb ^String line)
    (.append sb \newline)))

(defn emit!
  "Emit the event line `<seq> NAME fields...`.  Fields are converted with
  `str`."
  [g ename & fields]
  (let [n (inc (:seq @g))
        ^StringBuilder sb (:out @g)]
    (swap! g assoc :seq n)
    (.append sb n)
    (.append sb \space)
    (.append sb ^String ename)
    (doseq [f fields]
      (.append sb \space)
      (.append sb (str f)))
    (.append sb \newline)))

(defn signed
  "Render `n` with an explicit sign."
  [n]
  (if (neg? n) (str n) (str "+" n)))

;; ----- object creation and zones

(defn new-object!
  "Create an object for card `cid` owned by `owner`, appended to the
  `zone` (:vault/:hand/:ash/:rift) of its owner.  Returns the new oid."
  [g cid owner zone]
  (let [s @g
        oid (:next-oid s)
        d (get (:db s) cid)
        o {:oid oid :cid cid :def d :owner owner :zone zone :ts 0 :last-ctrl nil}]
    (upd-facets! g (if (#{:vault :hand :ash :rift} zone) #{zone} #{})
              (fn [s]
              (-> s
                  (assoc :next-oid (inc oid))
                  (assoc-in [:objs oid] o)
                  (cond-> (#{:vault :hand :ash :rift} zone)
                    (update-in [:zones owner zone] conj oid)))))
    oid))

(defn- remove-oid [v oid]
  (let [i (.indexOf ^java.util.List v oid)]
    (if (neg? i) v (into (subvec v 0 i) (subvec v (inc i))))))

(defn zone-remove!
  "Remove object `oid` from whichever zone it is in (not the Field and not
  the Chain, which have their own handling).  Returns the zone keyword."
  [g oid]
  (let [o (obj @g oid)
        z (:zone o)
        p (:owner o)]
    (when (#{:vault :hand :ash :rift} z)
      (upd-facets! g #{z} (fn [s]
                (update-in s [:zones p z]
                           (fn [zv]
                             (if (= z :vault)
                               (if (= (peek zv) oid)
                                 (pop zv)
                                 (into clojure.lang.PersistentQueue/EMPTY (remove #{oid}) zv))
                               (remove-oid zv oid)))))))
    z))

(defn zone-append!
  "Append `oid` to the `zone` of its owner and record the zone on the
  object."
  [g oid zone]
  (let [o (obj @g oid)]
    (upd-facets! g #{zone}
                 (fn [s]
                   (-> s
                       (assoc-in [:objs oid :zone] zone)
                       (update-in [:zones (:owner o) zone] conj oid))))))

(defn vault-pop!
  "Remove and return the top card of `p`'s Vault, or nil when empty."
  [g p]
  (let [q (get-in @g [:zones p :vault])]
    (when-let [oid (peek q)]
      (upd-facets! g #{:vault} update-in [:zones p :vault] pop)
      oid)))

(defn clear-field-state [o]
  (dissoc o :ctrl :ready :wounds :counters :ward :doomed :since :attacking
          :blocking :blockers :blocked :tenused :once))

(defn fresh-field-state [o ctrl turn]
  (assoc o :ctrl ctrl :ready true :wounds 0 :counters 0 :ward 0 :doomed false
         :since turn :attacking false :blocking nil :blockers [] :blocked false
         :tenused false :once #{}))

