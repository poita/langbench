(ns cardgame.cards
  "Card model and validator.

  [[parse-database]] turns the text of a card database into a *card table*:
  a map from card id (a String such as \"CIN-003\") to a card map.  Abilities
  are compiled once into a tree of keyword-tagged vectors that the effect
  interpreter walks:

  * amounts      `3`, `[:count sel]`, `[:hand psel]`, `[:wounds sel]` ...
  * selectors    `:self`, `[:t 1]`, `[:units :yours [filter ...]]` ...
  * players      `:you`, `:foe`, `:both`, `[:t 1]`, `[:owner-of sel]`
  * filters      `[:kw \"vanguard\"]`, `[:cost :le 2]`, `[:not f]` ...
  * conditions   `[:spire psel :ge 5]`, `[:myturn]`, `[:and c ...]`
  * effects      `[:damage amt dsel]`, `[:each sel [effect ...]]` ...
  * statics      `[:modify a b sel]`, `[:when cond [static ...]]`

  A card map has the keys `:id :name :type :cost :body :tags :keywords :text
  :abilities :triggers`.  See `ability` below for the shape of an ability."
  (:require [clojure.string :as str]
            [cardgame.sexpr :as sx :refer [bad!]]))

;; ---------------------------------------------------------------------------
;; Vocabulary

(def keyword-names
  "The sixteen keywords of the game."
  #{"vanguard" "vigil" "riposte" "pierce" "ghostwalk" "skyhook" "venom"
    "siphon" "plating" "provoke" "spectral" "tenacity" "siegework"
    "shackled" "relentless" "swift"})

(def ^:private unit-only-keywords
  (disj keyword-names "swift"))

(def ^:private events
  #{"arrive" "leave" "dies" "ally-arrive" "enemy-arrive" "ally-dies"
    "enemy-dies" "turn-start" "your-turn-start" "turn-end" "your-turn-end"
    "attacks" "blocks" "blocked" "unblocked" "damaged" "deals-damage"
    "you-play-rite" "enemy-plays-rite" "you-draw" "spire-loss"
    "enemy-spire-loss" "end-of-combat"})

(def ^:private cmps {'le :le 'lt :lt 'eq :eq 'ge :ge 'gt :gt 'ne :ne})
(def ^:private scopes {'yours :yours 'theirs :theirs 'all :all})
(def ^:private zones {'hand :hand 'ash :ash 'vault :vault 'rift :rift})
(def ^:private card-types {'unit :unit 'rite :rite 'relic :relic})
(def ^:private delay-whens
  {'turn-end :turn-end 'end-of-combat :end-of-combat
   'your-next-turn-start :your-next-turn-start})

(def ^:dynamic *refs*
  "Atom collecting [:summon id] / [:conjure id] references while compiling."
  nil)

;; ---------------------------------------------------------------------------
;; Small helpers for walking forms

(defn- head [f] (when (and (vector? f) (seq f)) (first f)))
(defn- args [f] (subvec f 1))
(defn- hname
  "The name of the symbol heading list `f`, or nil."
  [f]
  (let [h (head f)] (when (symbol? h) (name h))))
(defn- is-int? [x] (integer? x))
(defn- check! [ok] (when-not ok (bad!)))

(defn- arity! [f n] (check! (= (count f) (inc n))))

(defn- sym! [x] (check! (symbol? x)) x)

(defn- lookup! [m x] (check! (symbol? x)) (or (get m x) (bad!)))

(defn- cmp! [x] (lookup! cmps x))
(defn- int! [x] (check! (is-int? x)) x)

;; ---------------------------------------------------------------------------
;; Keywords

(defn kw-spec
  "Compile a keyword spec (`vanguard` or `(plating 2)`) to `{:kw name :n n}`."
  [x]
  (cond
    (symbol? x) (let [s (name x)]
                  (check! (and (keyword-names s) (not= s "plating")))
                  {:kw s :n nil})
    (and (vector? x) (= 2 (count x)) (= 'plating (first x)) (is-int? (second x)))
    {:kw "plating" :n (second x)}
    :else (bad!)))

(defn render-kw
  "Render a keyword instance as in the output: `plating:N` or its name."
  [{:keys [kw n]}]
  (if (= kw "plating") (str "plating:" n) kw))

;; ---------------------------------------------------------------------------
;; Filters, selectors, amounts, conditions

(defn- filter-kw-name [x]
  (check! (and (symbol? x) (keyword-names (name x))))
  (name x))

(declare compile-sel)

(defn- compile-filter [f]
  (check! (vector? f))
  (case (hname f)
    "kw"       (do (arity! f 1) [:kw (filter-kw-name (f 1))])
    "no-kw"    (do (arity! f 1) [:no-kw (filter-kw-name (f 1))])
    "tag"      (do (arity! f 1) [:tag (name (sym! (f 1)))])
    "type"     (do (arity! f 1) [:type (lookup! card-types (f 1))])
    "cost"     (do (arity! f 2) [:cost (cmp! (f 1)) (int! (f 2))])
    "edge"     (do (arity! f 2) [:edge (cmp! (f 1)) (int! (f 2))])
    "core"     (do (arity! f 2) [:core (cmp! (f 1)) (int! (f 2))])
    "wounded"   (do (arity! f 0) [:wounded])
    "ready"     (do (arity! f 0) [:ready])
    "exhausted" (do (arity! f 0) [:exhausted])
    "settling"  (do (arity! f 0) [:settling])
    "attacking" (do (arity! f 0) [:attacking])
    "blocking"  (do (arity! f 0) [:blocking])
    "mine"      (do (arity! f 0) [:mine])
    "enemy"     (do (arity! f 0) [:enemy])
    "other"     (do (arity! f 0) [:other])
    "not"      (do (arity! f 1) [:not (compile-filter (f 1))])
    (bad!)))

(defn- compile-filters [fs]
  (mapv compile-filter fs))

(defn- compile-t [f]
  (arity! f 1)
  (let [n (f 1)]
    (check! (and (is-int? n) (pos? n)))
    [:t n]))

(defn- compile-sel [f]
  (cond
    (symbol? f) (case (name f)
                  "self" :self
                  "it"   :it
                  "that" :that
                  (bad!))
    (vector? f)
    (case (hname f)
      "t"      (compile-t f)
      "units"  (do (check! (>= (count f) 2))
                   [:units (lookup! scopes (f 1)) (compile-filters (subvec f 2))])
      "relics" (do (check! (>= (count f) 2))
                   [:relics (lookup! scopes (f 1)) (compile-filters (subvec f 2))])
      "cards"  (do (check! (>= (count f) 3))
                   [:cards (lookup! zones (f 1)) (lookup! scopes (f 2))
                    (compile-filters (subvec f 3))])
      "random-unit" (do (check! (>= (count f) 2))
                        [:random-unit (lookup! scopes (f 1))
                         (compile-filters (subvec f 2))])
      (bad!))
    :else (bad!)))

(defn- compile-psel [f]
  (cond
    (symbol? f) (case (name f)
                  "you" :you "foe" :foe "both" :both
                  (bad!))
    (and (vector? f) (= 't (head f))) (compile-t f)
    (and (vector? f) (= 'owner-of (head f)))
    (do (arity! f 1) [:owner-of (compile-sel (f 1))])
    :else (bad!)))

(defn- psel-form? [f]
  (or (and (symbol? f) (#{"you" "foe" "both"} (name f)))
      (and (vector? f) (= 'owner-of (head f)))))

(defn- compile-dsel [f]
  (if (psel-form? f) (compile-psel f) (compile-sel f)))

(defn- compile-amt [f]
  (cond
    (is-int? f) f
    (vector? f)
    (case (hname f)
      "count"  (do (arity! f 1) [:count (compile-sel (f 1))])
      "hand"   (do (arity! f 1) [:hand (compile-psel (f 1))])
      "ash"    (do (arity! f 1) [:ash (compile-psel (f 1))])
      "vault"  (do (arity! f 1) [:vault (compile-psel (f 1))])
      "edge"   (do (arity! f 1) [:edge (compile-sel (f 1))])
      "core"   (do (arity! f 1) [:core (compile-sel (f 1))])
      "wounds" (do (arity! f 1) [:wounds (compile-sel (f 1))])
      (bad!))
    :else (bad!)))

(defn- compile-cond [f]
  (check! (vector? f))
  (case (hname f)
    "count"  (do (arity! f 3) [:count (compile-sel (f 1)) (cmp! (f 2)) (int! (f 3))])
    "spire"  (do (arity! f 3) [:spire (compile-psel (f 1)) (cmp! (f 2)) (int! (f 3))])
    "hand"   (do (arity! f 3) [:hand (compile-psel (f 1)) (cmp! (f 2)) (int! (f 3))])
    "ash"    (do (arity! f 3) [:ash (compile-psel (f 1)) (cmp! (f 2)) (int! (f 3))])
    "vault"  (do (arity! f 3) [:vault (compile-psel (f 1)) (cmp! (f 2)) (int! (f 3))])
    "ember"  (do (arity! f 3) [:ember (compile-psel (f 1)) (cmp! (f 2)) (int! (f 3))])
    "myturn" (do (arity! f 0) [:myturn])
    "and"    [:and (mapv compile-cond (args f))]
    "or"     [:or (mapv compile-cond (args f))]
    "not"    (do (arity! f 1) [:not (compile-cond (f 1))])
    (bad!)))

;; ---------------------------------------------------------------------------
;; Effects

(declare compile-effect)

(defn- compile-effects [fs]
  (check! (vector? fs))
  (mapv compile-effect fs))

(defn- card-ref! [kind id]
  (check! (symbol? id))
  (when *refs* (swap! *refs* conj [kind (name id)]))
  (name id))

(defn- compile-effect [f]
  (check! (vector? f))
  (case (hname f)
    "damage"   (do (arity! f 2) [:damage (compile-amt (f 1)) (compile-dsel (f 2))])
    "destroy"  (do (arity! f 1) [:destroy (compile-sel (f 1))])
    "sacrifice" (do (arity! f 1) [:sacrifice (compile-sel (f 1))])
    "exile"    (do (arity! f 1) [:exile (compile-sel (f 1))])
    "bounce"   (do (arity! f 1) [:bounce (compile-sel (f 1))])
    "draw"     (do (arity! f 2) [:draw (compile-amt (f 1)) (compile-psel (f 2))])
    "discard"  (do (arity! f 2) [:discard (compile-amt (f 1)) (compile-psel (f 2))])
    "mill"     (do (arity! f 2) [:mill (compile-amt (f 1)) (compile-psel (f 2))])
    "spire"    (do (arity! f 2) [:spire (compile-amt (f 1)) (compile-psel (f 2))])
    "ember"    (do (arity! f 2) [:ember (compile-amt (f 1)) (compile-psel (f 2))])
    "cap"      (do (arity! f 2) [:cap (compile-amt (f 1)) (compile-psel (f 2))])
    "modify"   (do (arity! f 3) [:modify (compile-amt (f 1)) (compile-amt (f 2)) (compile-sel (f 3))])
    "setbody"  (do (arity! f 3) [:setbody (compile-amt (f 1)) (compile-amt (f 2)) (compile-sel (f 3))])
    "swapstats" (do (arity! f 1) [:swapstats (compile-sel (f 1))])
    "grant"    (do (arity! f 2) [:grant (kw-spec (f 1)) (compile-sel (f 2))])
    "strip"    (do (arity! f 1) [:strip (compile-sel (f 1))])
    "control"  (do (arity! f 1) [:control (compile-sel (f 1))])
    "counters" (do (arity! f 2) [:counters (compile-amt (f 1)) (compile-sel (f 2))])
    "ready"    (do (arity! f 1) [:ready (compile-sel (f 1))])
    "exhaust"  (do (arity! f 1) [:exhaust (compile-sel (f 1))])
    "doom"     (do (arity! f 1) [:doom (compile-sel (f 1))])
    "ward"     (do (arity! f 2) [:ward (compile-amt (f 1)) (compile-sel (f 2))])
    "shield"   (do (arity! f 2) [:shield (compile-amt (f 1)) (compile-psel (f 2))])
    "summon"   (do (arity! f 3)
                   [:summon (card-ref! :summon (f 1)) (compile-amt (f 2)) (compile-psel (f 3))])
    "conjure"  (do (arity! f 3)
                   [:conjure (card-ref! :conjure (f 1)) (compile-amt (f 2)) (compile-psel (f 3))])
    "reanimate" (do (arity! f 1) [:reanimate (compile-sel (f 1))])
    "recall"   (do (arity! f 1) [:recall (compile-sel (f 1))])
    "negate"   (do (arity! f 1)
                   (check! (and (vector? (f 1)) (= 't (head (f 1)))))
                   [:negate (compile-t (f 1))])
    "dig"      (do (arity! f 3)
                   (check! (vector? (f 2)))
                   [:dig (int! (f 1)) (compile-filters (f 2)) (compile-psel (f 3))])
    "delay"    (do (check! (>= (count f) 2))
                   [:delay (lookup! delay-whens (f 1)) (compile-effects (subvec f 2))])
    "if"       (do (check! (<= 3 (count f) 4))
                   [:if (compile-cond (f 1)) (compile-effects (f 2))
                    (if (= 4 (count f)) (compile-effects (f 3)) [])])
    "each"     (do (check! (>= (count f) 2))
                   [:each (compile-sel (f 1)) (compile-effects (subvec f 2))])
    "repeat"   (do (check! (>= (count f) 2))
                   [:repeat (compile-amt (f 1)) (compile-effects (subvec f 2))])
    "nothing"  (do (arity! f 0) [:nothing])
    (bad!)))

;; ---------------------------------------------------------------------------
;; Statics, costs, target specifications

(defn- compile-cardfilter [f]
  (check! (vector? f))
  (case (hname f)
    "type" (do (arity! f 1) [:type (lookup! card-types (f 1))])
    "tag"  (do (arity! f 1) [:tag (name (sym! (f 1)))])
    "cost" (do (arity! f 2) [:cost (cmp! (f 1)) (int! (f 2))])
    (bad!)))

(defn- compile-static [f]
  (check! (vector? f))
  (case (hname f)
    "modify"    (do (arity! f 3) [:modify (compile-amt (f 1)) (compile-amt (f 2)) (compile-sel (f 3))])
    "setbody"   (do (arity! f 3) [:setbody (compile-amt (f 1)) (compile-amt (f 2)) (compile-sel (f 3))])
    "swapstats" (do (arity! f 1) [:swapstats (compile-sel (f 1))])
    "grant"     (do (arity! f 2) [:grant (kw-spec (f 1)) (compile-sel (f 2))])
    "cheaper"   (do (check! (>= (count f) 2))
                    [:cheaper (int! (f 1)) (mapv compile-cardfilter (subvec f 2))])
    "when"      (do (check! (>= (count f) 2))
                    [:when (compile-cond (f 1)) (mapv compile-static (subvec f 2))])
    (bad!)))

(defn- compile-costitem [f]
  (check! (vector? f))
  (case (hname f)
    "ember"   (do (arity! f 1) [:ember (int! (f 1))])
    "spire"   (do (arity! f 1) [:spire (int! (f 1))])
    "discard" (do (arity! f 1) [:discard (int! (f 1))])
    "exhaust" (do (arity! f 0) [:exhaust])
    "sacself" (do (arity! f 0) [:sacself])
    "counters" (do (arity! f 1) [:counters (int! (f 1))])
    "once"    (do (arity! f 0) [:once])
    (bad!)))

(defn- compile-tspec [f]
  (check! (vector? f))
  (case (hname f)
    "unit"    [:unit (compile-filters (args f))]
    "relic"   [:relic (compile-filters (args f))]
    "any"     [:any (compile-filters (args f))]
    "player"  (do (arity! f 0) [:player])
    "chained" (do (arity! f 0) [:chained])
    "ashcard" [:ashcard (compile-filters (args f))]
    (bad!)))

;; ---------------------------------------------------------------------------
;; Abilities

(defn- reads-of
  "The optional state facets (see `cardgame.state/upd-facets!`) read by a
  compiled aura tree."
  [tree]
  (reduce
   (fn [acc node]
     (cond
       (and (vector? node) (keyword? (first node)))
       (case (first node)
         (:wounded :wounds) (conj acc :wounds)
         (:ready :exhausted) (conj acc :ready)
         :settling (conj acc :since)
         (:attacking :blocking) (conj acc :combat)
         :cards (conj acc (second node))
         (:hand :ash :vault :spire :ember) (conj acc (first node))
         acc)
       :else acc))
   #{} (tree-seq vector? seq tree)))

(defn- compile-parts
  "Compile the parts of a `resolve`, `on` or `act` clause.  `allow-cost?` is
  true only for `act`.  Returns {:cost :targets :effects :cost-form
  :targets-form}."
  [parts allow-cost?]
  (loop [ps parts, cost nil, targets nil, effects [], cost-form nil, targets-form nil]
    (if-let [[p & more] (seq ps)]
      (do
        (check! (vector? p))
        (case (hname p)
          "cost" (do (check! (and allow-cost? (nil? cost) (empty? effects)))
                     (recur more (mapv compile-costitem (args p)) targets effects p targets-form))
          "targets" (do (check! (and (nil? targets) (empty? effects) (>= (count p) 2)))
                        (recur more cost (mapv compile-tspec (args p)) effects cost-form p))
          (recur more cost targets (conj effects (compile-effect p)) cost-form targets-form)))
      (do (check! (and (seq effects) (or (not allow-cost?) cost)))
          {:cost cost :targets (or targets []) :effects effects
           :cost-form cost-form :targets-form targets-form}))))

(defn- join-forms [fs] (str/join " " (map sx/print-form fs)))

(defn- raw-parts [parts]
  (filterv #(not (#{'cost 'targets} (first %))) parts))

(defn- compile-ability [n kind f]
  (case kind
    :resolve
    (let [parts (args f)
          c (compile-parts parts false)]
      (assoc c :n n :kind :resolve
             :render (str "resolve " (if-let [t (:targets-form c)] (sx/print-form t) "-")
                          " " (join-forms (raw-parts parts)))))
    :on
    (do (check! (>= (count f) 2))
        (let [ev (sym! (f 1))
              parts (subvec f 2)
              _ (check! (events (name ev)))
              c (compile-parts parts false)]
          (assoc c :n n :kind :on :event (name ev)
                 :render (str "on " (name ev) " "
                              (if-let [t (:targets-form c)] (sx/print-form t) "-")
                              " " (join-forms (raw-parts parts))))))
    :act
    (let [parts (args f)
          c (compile-parts parts true)]
      (assoc c :n n :kind :act
             :render (str "act " (sx/print-form (:cost-form c)) " "
                          (if-let [t (:targets-form c)] (sx/print-form t) "-")
                          " " (join-forms (raw-parts parts)))))
    :aura
    (let [statics (args f)]
      (check! (seq statics))
      {:n n :kind :aura :statics (mapv compile-static statics)
       :reads (reads-of (mapv compile-static statics))
       :render (str "aura " (join-forms statics))})))

;; ---------------------------------------------------------------------------
;; Cards

(defn- compile-keywords [forms]
  (mapv kw-spec forms))

(defn- compile-card [form]
  (check! (and (vector? form) (>= (count form) 2) (= 'card (first form))))
  (let [id (sym! (form 1))
        id (name id)
        _ (check! (re-matches #"[A-Z]{3}-[0-9]{3}" id))
        clauses (subvec form 2)
        by (fn [h] (filterv #(= h (head %)) clauses))
        once (fn [h] (let [cs (by h)] (check! (<= (count cs) 1)) (first cs)))
        one  (fn [h] (let [c (once h)] (check! c) c))]
    (doseq [c clauses]
      (check! (and (vector? c) (#{'name 'type 'cost 'body 'tags 'keywords 'text
                                  'resolve 'on 'act 'aura} (head c)))))
    (let [name-c (one 'name)
          _ (check! (and (= 2 (count name-c)) (string? (name-c 1))))
          type-c (one 'type)
          _ (check! (= 2 (count type-c)))
          type (lookup! card-types (type-c 1))
          cost-c (one 'cost)
          _ (check! (and (= 2 (count cost-c)) (is-int? (cost-c 1)) (>= (cost-c 1) 0)))
          body-c (once 'body)
          _ (if (= type :unit)
              (check! (and body-c (= 3 (count body-c)) (is-int? (body-c 1)) (is-int? (body-c 2))
                           (>= (body-c 1) 0) (>= (body-c 2) 0)))
              (check! (nil? body-c)))
          tags-c (once 'tags)
          tags (if tags-c (mapv (fn [t] (name (sym! t))) (args tags-c)) [])
          kw-c (once 'keywords)
          kws (if kw-c (compile-keywords (args kw-c)) [])
          _ (doseq [k kws]
              (check! (if (= type :rite)
                        (#{"swift"} (:kw k))
                        (if (= type :unit)
                          (unit-only-keywords (:kw k))
                          false))))
          text-c (once 'text)
          _ (when text-c (check! (and (= 2 (count text-c)) (string? (text-c 1)))))
          resolves (by 'resolve)
          _ (check! (if (= type :rite) (= 1 (count resolves)) (empty? resolves)))
          abil-forms (concat (map (fn [f] [:resolve f]) resolves)
                             (map (fn [f] [:on f]) (by 'on))
                             (map (fn [f] [:act f]) (by 'act))
                             (map (fn [f] [:aura f]) (by 'aura)))
          abilities (vec (map-indexed (fn [i [k f]] (compile-ability (inc i) k f)) abil-forms))]
      {:id id
       :name (name-c 1)
       :type type
       :cost (cost-c 1)
       :body (when body-c [(body-c 1) (body-c 2)])
       :tags tags
       :keywords kws
       :text (when text-c (text-c 1))
       :abilities abilities
       ;; event -> [ability indices] for fast trigger collection
       :triggers (reduce (fn [m a] (if (= :on (:kind a))
                                     (update m (:event a) (fnil conj []) (:n a))
                                     m))
                         {} abilities)
       :auras (filterv #(= :aura (:kind %)) abilities)})))

(defn parse-database
  "Parse and validate the text of a card database.  Returns the card table
  (a map from id to card).  Throws an exception for which
  [[cardgame.sexpr/bad-database?]] is true when the text is not a valid
  database."
  [text]
  (binding [*refs* (atom [])]
    (let [forms (sx/read-all text)
          cards (mapv compile-card forms)
          table (reduce (fn [m c]
                          (check! (not (contains? m (:id c))))
                          (assoc m (:id c) c))
                        {} cards)]
      (doseq [[kind id] @*refs*]
        (let [c (get table id)]
          (check! c)
          (when (= kind :summon) (check! (not= :rite (:type c))))))
      table)))

(defn load-database
  "Read and validate the database at `path`.  Returns the card table or
  throws as [[parse-database]] does (an unreadable file is a bad database
  too)."
  [path]
  (let [text (try (slurp path :encoding "UTF-8")
                  (catch java.io.IOException _ (bad! "cannot read database")))]
    (try (parse-database text)
         (catch StackOverflowError _ (bad! "nesting too deep")))))

;; ---------------------------------------------------------------------------
;; Rendering for the CARD directive

(defn render-card
  "The lines of the `CARD BEGIN ... CARD END` block for `card`, which may be
  nil for an unknown id (in which case `id` is used)."
  [id card]
  (if-not card
    [(str "CARD BEGIN " id) "unknown" "CARD END"]
    (concat
     [(str "CARD BEGIN " id)
      (str "name " (:name card))
      (str "type " (clojure.core/name (:type card)))
      (str "cost " (:cost card))]
     (when-let [[e c] (:body card)] [(str "body " e "/" c)])
     [(str "tags " (if (seq (:tags card)) (str/join "," (:tags card)) "-"))
      (str "keywords " (if (seq (:keywords card))
                         (str/join "," (sort (map render-kw (:keywords card))))
                         "-"))]
     (map (fn [a] (str "ability " (:n a) " " (:render a))) (:abilities card))
     ["CARD END"])))
