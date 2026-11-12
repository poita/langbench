(ns typeinfer.infer
  "Hindley-Milner inference (Algorithm J with level-based generalisation) over
  the syntax trees produced by `typeinfer.parser`.

  An *environment* is a persistent map from names to bindings. A binding is
  either a monomorphic type (lambda parameters, a recursive function inside
  its own body), used as it is, or a `Scheme` (let-bound), instantiated at
  each use. Lookup is a single map access and generalisation never scans the
  environment."
  (:require [typeinfer.types :as t]))

(set! *warn-on-reflection* true)

(defrecord Scheme [type])

(defn- unbound [name]
  (throw (ex-info (str "unbound variable " name) {:kind :unbound :name name})))

(def ^:private operators
  "Operator -> [operand type, result type]."
  {"+" [t/int-type t/int-type], "-" [t/int-type t/int-type]
   "*" [t/int-type t/int-type], "/" [t/int-type t/int-type]
   "=" [t/int-type t/bool-type], "<" [t/int-type t/bool-type]
   ">" [t/int-type t/bool-type], "<=" [t/int-type t/bool-type]
   ">=" [t/int-type t/bool-type]
   "&&" [t/bool-type t/bool-type], "||" [t/bool-type t/bool-type]})

(declare infer)

(defn- infer-fun [env ^long level {:keys [params body]}]
  (let [[env' vars] (reduce (fn [[env vars] p]
                              (let [v (t/fresh-var level)]
                                [(assoc env p v) (conj vars v)]))
                            [env []]
                            params)
        body-type (infer env' level body)]
    (reduce (fn [acc v] (t/arrow v acc)) body-type (rseq vars))))

(defn- infer-let
  "Infer a `let`/`let rec` right-hand side one level deeper, generalise it,
  and return the extended environment."
  [env level rec? name rhs]
  (let [inner (inc level)
        ty (if rec?
             (let [f (t/fresh-var inner)
                   ty (infer (assoc env name f) inner rhs)]
               (t/unify f ty)
               ty)
             (infer env inner rhs))]
    (t/generalize! ty level)
    (assoc env name (->Scheme ty))))

(defn- infer-seq-unify
  "Infer each of `elems` in order and unify its type with `elem-type`."
  [env level elems elem-type]
  (doseq [e elems]
    (t/unify (infer env level e) elem-type)))

(defn infer
  "Infer the type of expression `e` in `env` at let-nesting `level`,
  unifying as it goes. Returns a type; throws `ex-info` with
  `{:kind :unbound | :unify | :occurs}` on failure."
  [env ^long level e]
  (case (:op e)
    :int t/int-type
    :bool t/bool-type
    :unit t/unit-type
    :nil (t/list-of (t/fresh-var level))
    :var (let [name (:name e)
               b (get env name ::none)]
           (cond
             (identical? b ::none) (unbound name)
             (instance? Scheme b) (t/instantiate (:type b) level)
             :else b))
    :fun (infer-fun env level e)
    :app (let [tf (infer env level (:fn e))
               ta (infer env level (:arg e))
               r (t/fresh-var level)]
           (t/unify tf (t/arrow ta r))
           r)
    :if (let [c (infer env level (:cond e))
              _ (t/unify c t/bool-type)
              a (infer env level (:then e))
              b (infer env level (:else e))]
          (t/unify a b)
          a)
    :let (infer (infer-let env level false (:name e) (:rhs e)) level (:body e))
    :letrec (infer (infer-let env level true (:name e) (:rhs e)) level (:body e))
    :tuple (t/tuple-of (mapv #(infer env level %) (:elems e)))
    :list (let [v (t/fresh-var level)]
            (infer-seq-unify env level (:elems e) v)
            (t/list-of v))
    :cons (let [h (infer env level (:head e))
                tl (infer env level (:tail e))]
            (t/unify tl (t/list-of h))
            tl)
    :binop (let [[operand result] (operators (:operator e))
                 l (infer env level (:left e))
                 _ (t/unify l operand)
                 r (infer env level (:right e))]
             (t/unify r operand)
             result)))

(defn initial-env
  "The initial environment holding the built-in functions."
  []
  (let [scheme (fn [mk] (->Scheme (mk)))
        v t/generic-var
        ->  t/arrow
        lst t/list-of
        pair (fn [a b] (t/tuple-of [a b]))]
    {"not" (scheme #(-> t/bool-type t/bool-type))
     "fst" (scheme #(let [a (v) b (v)] (-> (pair a b) a)))
     "snd" (scheme #(let [a (v) b (v)] (-> (pair a b) b)))
     "hd" (scheme #(let [a (v)] (-> (lst a) a)))
     "tl" (scheme #(let [a (v)] (-> (lst a) (lst a))))
     "null" (scheme #(-> (lst (v)) t/bool-type))
     "length" (scheme #(-> (lst (v)) t/int-type))
     "map" (scheme #(let [a (v) b (v)]
                      (-> (-> a b) (-> (lst a) (lst b)))))
     "fold" (scheme #(let [a (v) b (v)]
                       (-> (-> a (-> b a)) (-> a (-> (lst b) a)))))}))

(defn infer-decl
  "Infer one declaration (see `typeinfer.parser`) in the top-level `env`.
  Returns `[env' type]`: for a `:let`/`:letrec` declaration `env'` binds the
  name to the generalised type; for an `:expr` it is `env` unchanged. Throws
  like `infer` on failure, in which case the caller keeps `env`."
  [env {:keys [kind name expr]}]
  (case kind
    :expr [env (infer env 1 expr)]
    (:let :letrec)
    (let [env' (infer-let env 0 (= kind :letrec) name expr)]
      [env' (:type (get env' name))])))
