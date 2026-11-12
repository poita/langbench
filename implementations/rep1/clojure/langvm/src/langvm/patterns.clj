(ns langvm.patterns
  "Pattern typing, irrefutability and the usefulness algorithm
  (SPEC section 12).

  Typed patterns are maps with a `:k`:

    {:k :wild}                       {:k :bind :b binding}
    {:k :lit :ty :int|:str|:char|:bool :v value}
    {:k :variant :decl d :vidx i :args [pat ...]}
    {:k :struct :decl d :fields [pat ...]}     ; declaration order
    {:k :tuple :elems [pat ...]}
    {:k :list :elems [pat ...] :rest nil|:open :rest-bind binding-or-nil}"
  (:require [langvm.diag :as diag]
            [langvm.names :as names]
            [langvm.types :as t]))

(set! *warn-on-reflection* true)

(defn- mismatch [p] (diag/fail :type-mismatch p))

(defn- decl-of [prog id] (nth (:decls prog) id))

(defn- named-subst
  "Map from the declaration's type parameters to the type arguments of `ty`."
  [prog ty]
  (zipmap (:tparams (decl-of prog (nth ty 1))) (nth ty 2)))

(declare check-pat)

(defn- bind!
  "Introduce binding `name`; `ctx` is `{:bound atom :mk fn}`."
  [{:keys [bound mk]} name ty p]
  (when (contains? @bound name) (diag/fail :dup-name p))
  (let [b (mk name ty)]
    (swap! bound assoc name b)
    {:k :bind :b b}))

(defn- check-pats [prog mi ctx pats tys]
  (mapv (fn [p ty] (check-pat prog mi ctx p ty)) pats tys))

(defn- check-variant [prog mi ctx pat ty r]
  (let [[_ d vi] r
        _ (when-not (= :variant (first r)) (mismatch (:pos pat)))
        ty (t/prune ty)]
    (when-not (and (vector? ty) (= :named (nth ty 0)) (= d (nth ty 1)))
      (mismatch (:pos pat)))
    (let [v (nth (:variants (decl-of prog d)) vi)
          args (or (:args pat) [])]
      (when-not (= (count args) (count (:payload v))) (diag/fail :arity (:pos pat)))
      (let [m (named-subst prog ty)
            tys (mapv #(t/subst-params % m) (:payload v))]
        {:k :variant :decl d :vidx vi :args (check-pats prog mi ctx args tys)}))))

(defn- check-struct [prog mi ctx pat ty]
  (let [path (:path pat)
        d (names/resolve-struct-type prog mi path)
        dd (decl-of prog d)
        ty (t/prune ty)]
    (when-not (and (vector? ty) (= :named (nth ty 0)) (= d (nth ty 1)))
      (mismatch (:pos pat)))
    (let [fnames (mapv :name (:fields dd))
          written (:fields pat)]
      (reduce (fn [seen f]
                (when (contains? seen (:name f)) (diag/fail :dup-field (:pos f)))
                (when-not (some #{(:name f)} fnames) (diag/fail :unknown-field (:pos f)))
                (conj seen (:name f)))
              #{} written)
      (when (and (not (:rest? pat)) (not= (count written) (count fnames)))
        (diag/fail :missing-field (:pos pat)))
      (let [m (named-subst prog ty)
            ftys (zipmap fnames (map #(t/subst-params (:ty %) m) (:fields dd)))
            subs (reduce (fn [acc f]
                           (let [fty (get ftys (:name f))
                                 sub (if (:pat f)
                                       (check-pat prog mi ctx (:pat f) fty)
                                       (bind! ctx (:name f) fty (:pos f)))]
                             (assoc acc (:name f) sub)))
                         {} written)]
        {:k :struct :decl d
         :fields (mapv #(get subs % {:k :wild}) fnames)}))))

(defn check-pat
  "Type pattern `pat` against type `ty`, introducing bindings through `ctx`
  (`{:bound (atom {}) :mk (fn [name type] binding)}`).  Returns the typed
  pattern."
  [prog mi ctx pat ty]
  (case (:p pat)
    :wild {:k :wild}
    :name
    (let [r (names/bare-variant prog mi (:name pat))]
      (if (and r (empty? (:payload (nth (:variants (decl-of prog (second r))) (nth r 2)))))
        (check-variant prog mi ctx pat ty r)
        (bind! ctx (:name pat) ty (:pos pat))))
    :lit
    (let [kind (:kind pat)
          ty (t/prune ty)]
      (when (= kind :float) (diag/fail :bad-pattern (:pos pat)))
      (when-not (= ty kind) (mismatch (:pos pat)))
      {:k :lit :ty kind :v (:v pat)})
    :variant
    (let [path (:path pat)
          r (names/resolve-value prog mi (assoc path :pos (:pos pat)) nil)]
      (check-variant prog mi ctx pat ty r))
    :struct (check-struct prog mi ctx pat ty)
    :tuple
    (let [ty (t/prune ty)]
      (when-not (and (vector? ty) (= :tuple (nth ty 0)) (= (count (:elems pat)) (dec (count ty))))
        (mismatch (:pos pat)))
      {:k :tuple :elems (check-pats prog mi ctx (:elems pat) (vec (rest ty)))})
    :list
    (let [ty (t/prune ty)]
      (when-not (and (vector? ty) (= :list (nth ty 0))) (mismatch (:pos pat)))
      (let [e (nth ty 1)
            elems (mapv #(check-pat prog mi ctx % e) (:elems pat))
            rest (:rest pat)]
        {:k :list :elems elems
         :rest (when rest :open)
         :rest-bind (when (map? rest)
                      (:b (bind! ctx (:name rest) [:list e] (:pos rest))))}))))

;; ---------------------------------------------------------------------------
;; irrefutability (12.6)

(defn irrefutable?
  [prog p]
  (case (:k p)
    (:wild :bind) true
    :lit false
    :tuple (every? #(irrefutable? prog %) (:elems p))
    :struct (every? #(irrefutable? prog %) (:fields p))
    :variant (and (== 1 (count (:variants (decl-of prog (:decl p)))))
                  (every? #(irrefutable? prog %) (:args p)))
    :list (and (= :open (:rest p)) (empty? (:elems p)))))

;; ---------------------------------------------------------------------------
;; usefulness (12.4)

(defn- wild? [p] (#{:wild :bind} (:k p)))

(def ^:private wild {:k :wild})

(defn- ctor-key
  "The constructor named by pattern `p`, or nil for a wildcard."
  [p]
  (case (:k p)
    (:wild :bind) nil
    :lit [:lit (:v p)]
    :variant [:variant (:vidx p)]
    (:struct :tuple) :single))

(defn- ctor-subpats [p]
  (case (:k p)
    :lit []
    :variant (:args p)
    :struct (:fields p)
    :tuple (:elems p)))

(defn- ctor-subtys
  "Types of the sub-patterns of constructor `key` at column type `ty`."
  [prog ty key]
  (let [ty (t/prune ty)]
    (cond
      (= key :single)
      (if (= :tuple (nth ty 0))
        (vec (rest ty))
        (let [m (named-subst prog ty)]
          (mapv #(t/subst-params (:ty %) m) (:fields (decl-of prog (nth ty 1))))))
      (= :variant (first key))
      (let [m (named-subst prog ty)]
        (mapv #(t/subst-params % m)
              (:payload (nth (:variants (decl-of prog (nth ty 1))) (second key)))))
      :else [])))

(defn- all-ctors
  "Keys of every constructor of column type `ty` when finite, else nil."
  [prog ty]
  (let [ty (t/prune ty)]
    (cond
      (= ty :bool) [[:lit true] [:lit false]]
      (= ty :unit) [:single]
      (keyword? ty) nil
      :else
      (case (nth ty 0)
        :tuple [:single]
        :named (let [d (decl-of prog (nth ty 1))]
                 (if (= :struct (:kind d))
                   [:single]
                   (mapv (fn [i] [:variant i]) (range (count (:variants d))))))
        nil))))

(defn- specialize-row [row key arity]
  (let [p (first row)]
    (cond
      (wild? p) (into (vec (repeat arity wild)) (rest row))
      (= key (ctor-key p)) (into (vec (ctor-subpats p)) (rest row))
      :else nil)))

(defn- specialize [rows key arity]
  (into [] (keep #(specialize-row % key arity)) rows))

(defn- list-row-at
  "Specialise a row whose first pattern is a list pattern or wildcard to
  length `k`."
  [row k]
  (let [p (first row)]
    (cond
      (wild? p) (into (vec (repeat k wild)) (rest row))
      :else
      (let [n (count (:elems p))]
        (if (:rest p)
          (when (<= n k) (into (into (vec (:elems p)) (repeat (- k n) wild)) (rest row)))
          (when (== n k) (into (vec (:elems p)) (rest row))))))))

(defn- admits? [p k]
  (cond
    (wild? p) true
    (:rest p) (<= (count (:elems p)) k)
    :else (== (count (:elems p)) k)))

(defn useful?
  "U(P, q): is row `q` useful against matrix `rows`, with column types `tys`?"
  [prog rows q tys]
  (if (empty? q)
    (empty? rows)
    (let [ty (t/prune (first tys))
          p (first q)]
      (if (and (vector? ty) (= :list (nth ty 0)))
        (let [lmax (reduce max 0 (map #(if (= :list (:k %)) (count (:elems %)) 0)
                                      (cons p (map first rows))))
              e (nth ty 1)]
          (boolean
           (some (fn [k]
                   (and (admits? p k)
                        (useful? prog
                                 (into [] (keep #(list-row-at % k)) rows)
                                 (list-row-at q k)
                                 (into (vec (repeat k e)) (rest tys)))))
                 (range 0 (+ lmax 2)))))
        (if-let [c (ctor-key p)]
          (let [sub (ctor-subtys prog ty c)
                ar (count sub)]
            (useful? prog (specialize rows c ar) (specialize-row q c ar) (into sub (rest tys))))
          (let [used (into [] (distinct) (keep #(ctor-key (first %)) rows))
                all (all-ctors prog ty)]
            (if (and all (every? (set used) all))
              (boolean
               (some (fn [c]
                       (let [sub (ctor-subtys prog ty c)
                             ar (count sub)]
                         (useful? prog (specialize rows c ar) (specialize-row q c ar)
                                  (into sub (rest tys)))))
                     used))
              (useful? prog
                       (into [] (keep #(when (wild? (first %)) (vec (rest %)))) rows)
                       (vec (rest q))
                       (vec (rest tys))))))))))

(defn first-unreachable
  "Index of the first unreachable arm, or nil.  `arms` is a vector of
  `{:pat typed-pattern :guard? bool}`."
  [prog arms ty]
  (loop [i 0, rows []]
    (when (< i (count arms))
      (let [{:keys [pat guard?]} (nth arms i)]
        (if-not (useful? prog rows [pat] [ty])
          i
          (recur (inc i) (if guard? rows (conj rows [pat]))))))))

(defn exhaustive?
  "Do the unguarded arms of `arms` cover type `ty`?"
  [prog arms ty]
  (not (useful? prog (into [] (keep #(when-not (:guard? %) [(:pat %)])) arms) [wild] [ty])))
