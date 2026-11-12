(ns langvm.types
  "Semantic types and unification (SPEC sections 6 and 9.2).

  A type is one of

  * a keyword `:int :float :bool :char :str :unit`,
  * `[:list T]`, `[:map K V]`, `[:tuple T1 ... Tn]`, `[:fn [P1 ... Pn] R]`,
  * `[:named decl-id [Arg ...]]` for a struct or enum instance,
  * `[:param uid]` for a rigid generic parameter,
  * `[:var id]` for an inference variable.

  Inference variables are solved in a substitution held in the dynamic var
  `*subst*`; use [[with-inference]] to establish one."
  (:refer-clojure :exclude [var?]))

(set! *warn-on-reflection* true)

(def ^:dynamic *subst* nil)
(def ^:dynamic *owner* nil)

(defmacro with-inference
  "Run `body` with a fresh substitution."
  [& body]
  `(binding [*subst* (atom {:next 0})
             *owner* (atom [])]
     ~@body))

(defn fresh-var
  "A new unsolved inference variable, registered with the innermost owner."
  []
  (let [id (:next @*subst*)
        v [:var id]]
    (swap! *subst* assoc :next (inc id))
    (swap! *owner* conj v)
    v))

(defn var? [t] (and (vector? t) (identical? :var (nth t 0))))

(defn prune
  "Resolve `t` at the head: follow solved variables."
  [t]
  (if (var? t)
    (let [s (get @*subst* (nth t 1))]
      (if s (recur s) t))
    t))

(defn zonk
  "Fully substitute solved variables in `t`."
  [t]
  (let [t (prune t)]
    (if (vector? t)
      (case (nth t 0)
        :list [:list (zonk (nth t 1))]
        :map [:map (zonk (nth t 1)) (zonk (nth t 2))]
        :tuple (into [:tuple] (map zonk (rest t)))
        :fn [:fn (mapv zonk (nth t 1)) (zonk (nth t 2))]
        :named [:named (nth t 1) (mapv zonk (nth t 2))]
        t)
      t)))

(defn ground?
  "True when `t` has no unsolved inference variable."
  [t]
  (let [t (prune t)]
    (if (vector? t)
      (case (nth t 0)
        :var false
        :list (ground? (nth t 1))
        :map (and (ground? (nth t 1)) (ground? (nth t 2)))
        :tuple (every? ground? (rest t))
        :fn (and (every? ground? (nth t 1)) (ground? (nth t 2)))
        :named (every? ground? (nth t 2))
        true)
      true)))

(defn- occurs? [v t]
  (let [t (prune t)]
    (if (vector? t)
      (case (nth t 0)
        :var (= v t)
        :list (occurs? v (nth t 1))
        :map (or (occurs? v (nth t 1)) (occurs? v (nth t 2)))
        :tuple (boolean (some #(occurs? v %) (rest t)))
        :fn (or (boolean (some #(occurs? v %) (nth t 1))) (occurs? v (nth t 2)))
        :named (boolean (some #(occurs? v %) (nth t 2)))
        false)
      false)))

(defn unify
  "Unify `a` and `b`, solving variables.  Returns true on success."
  [a b]
  (let [a (prune a), b (prune b)]
    (cond
      (and (var? a) (var? b) (= a b)) true
      (var? a) (if (occurs? a b) false (do (swap! *subst* assoc (nth a 1) b) true))
      (var? b) (if (occurs? b a) false (do (swap! *subst* assoc (nth b 1) a) true))
      (keyword? a) (= a b)
      (keyword? b) false
      (not= (nth a 0) (nth b 0)) false
      :else
      (case (nth a 0)
        :list (unify (nth a 1) (nth b 1))
        :map (and (unify (nth a 1) (nth b 1)) (unify (nth a 2) (nth b 2)))
        :tuple (and (= (count a) (count b))
                    (loop [i 1]
                      (cond (== i (count a)) true
                            (unify (nth a i) (nth b i)) (recur (inc i))
                            :else false)))
        :fn (and (= (count (nth a 1)) (count (nth b 1)))
                 (loop [x (nth a 1), y (nth b 1)]
                   (cond (empty? x) (unify (nth a 2) (nth b 2))
                         (unify (first x) (first y)) (recur (rest x) (rest y))
                         :else false)))
        :named (and (= (nth a 1) (nth b 1))
                    (loop [x (nth a 2), y (nth b 2)]
                      (cond (empty? x) true
                            (unify (first x) (first y)) (recur (rest x) (rest y))
                            :else false)))
        :param (= a b)))))

(defn subst-params
  "Replace `[:param uid]` in `t` according to the map `m` (uid -> type)."
  [t m]
  (if (empty? m)
    t
    (let [go (fn go [t]
               (if (vector? t)
                 (case (nth t 0)
                   :param (get m (nth t 1) t)
                   :list [:list (go (nth t 1))]
                   :map [:map (go (nth t 1)) (go (nth t 2))]
                   :tuple (into [:tuple] (map go (rest t)))
                   :fn [:fn (mapv go (nth t 1)) (go (nth t 2))]
                   :named [:named (nth t 1) (mapv go (nth t 2))]
                   t)
                 t))]
      (go t))))

(defn mentions-param?
  "True when type `t` mentions the parameter `uid`."
  [t uid]
  (if (vector? t)
    (case (nth t 0)
      :param (= uid (nth t 1))
      :list (mentions-param? (nth t 1) uid)
      :map (or (mentions-param? (nth t 1) uid) (mentions-param? (nth t 2) uid))
      :tuple (boolean (some #(mentions-param? % uid) (rest t)))
      :fn (or (boolean (some #(mentions-param? % uid) (nth t 1))) (mentions-param? (nth t 2) uid))
      :named (boolean (some #(mentions-param? % uid) (nth t 2)))
      false)
    false))

;; Head constructors ---------------------------------------------------------

(def ^:const con-int 0)
(def ^:const con-float 1)
(def ^:const con-bool 2)
(def ^:const con-char 3)
(def ^:const con-str 4)
(def ^:const con-unit 5)
(def ^:const con-list 6)
(def ^:const con-map 7)
(def ^:const con-decl-base 8)

(defn head-con
  "The head constructor number of type `t`, or nil for tuples, functions and
  parameters.  Named types map to `8 + decl-id`."
  [t]
  (let [t (prune t)]
    (if (keyword? t)
      (case t :int 0 :float 1 :bool 2 :char 3 :str 4 :unit 5)
      (case (nth t 0)
        :list 6
        :map 7
        :named (+ 8 (long (nth t 1)))
        nil))))
