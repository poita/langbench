(ns langvm.check
  "The type checker (SPEC sections 9 to 12, compiler pass 4).

  `(check-program prog)` checks every function body of the program built by
  `langvm.program/build` and returns a vector of typed bodies indexed by
  function id.  Checking is bidirectional: [[infer]] synthesises a type and
  [[check]] verifies against an expected one.  Both return an IR tree (vectors
  tagged with a keyword) in which names are resolved, generics are erased and
  arithmetic is specialised by type; `langvm.compile` lowers the IR to
  bytecode."
  (:require [langvm.diag :as diag]
            [langvm.names :as names]
            [langvm.patterns :as pat]
            [langvm.program :as program]
            [langvm.types :as t]))

(set! *warn-on-reflection* true)

(def ^:dynamic *prog* nil)
(def ^:dynamic *counter* nil)

(defn- next-id! [] (swap! *counter* inc))

(defn- mismatch [p] (diag/fail :type-mismatch p))
(defn- prune [ty] (t/prune ty))

(declare infer check infer-block check-block check-stmts check-block-stmt check-fn-body-ir)

;; ---------------------------------------------------------------------------
;; environments and bindings

(defn- new-binding [env name ty mutable?]
  {:id (next-id!) :name name :type ty :mutable? mutable? :fn (:fn env)})

(defn- with-locals [env bindings]
  (update env :locals into (map (fn [b] [(:name b) b])) bindings))

(defn- use-binding!
  "Record captures when binding `b` is used from a nested lambda."
  [env b]
  (let [ctxs (:ctxs env)]
    (loop [i (dec (count ctxs))]
      (let [ctx (nth ctxs i)]
        (when-not (== (:id ctx) (:fn b))
          (swap! (:caps ctx) (fn [caps] (if (some #(== (:id %) (:id b)) caps) caps (conj caps b))))
          (recur (dec i)))))))

(defn- rtype [env ast]
  (program/resolve-type *prog* env ast))

(defn- type-env [env] (select-keys env [:mod :tscope :self]))

;; ---------------------------------------------------------------------------
;; divergence (11.6)

(defn diverges?
  "Does control never flow past AST node `n` (statement or expression)?"
  [n]
  (if (:s n)
    (case (:s n)
      (:return :break :continue) true
      :let (diverges? (:init n))
      :var (diverges? (:init n))
      :assign (diverges? (:value n))
      :expr (diverges? (:expr n))
      false)
    (case (:e n)
      :block (boolean (or (some diverges? (:stmts n))
                          (and (:tail n) (diverges? (:tail n)))))
      :if (boolean (and (:else n) (diverges? (:then n)) (diverges? (:else n))))
      :match (boolean (and (seq (:arms n)) (every? #(diverges? (:body %)) (:arms n))))
      false)))

;; ---------------------------------------------------------------------------
;; calls

(defn- generic-call
  "The generic call rule of 9.4.  Returns [type ir]."
  [env pos tparams params ret args expected build]
  (when-not (= (count args) (count params)) (diag/fail :arity pos))
  (binding [t/*owner* (atom [])]
    (let [vars (mapv (fn [_] (t/fresh-var)) tparams)
          sigma (zipmap (map :uid tparams) vars)
          irs (mapv (fn [a p] (check env a (t/subst-params p sigma))) args params)
          rt (t/subst-params ret sigma)]
      (when expected
        (when-not (t/unify rt expected) (mismatch pos)))
      (when-not (every? t/ground? @t/*owner*) (diag/fail :cannot-infer pos))
      (doseq [[tp v] (map vector tparams vars)
              b (:bounds tp)]
        (when-not (program/holds? *prog* (t/zonk v) b) (diag/fail :unsatisfied-bound pos)))
      [(t/zonk rt) (build irs)])))

(defn- variant-sig [d]
  (let [tps (mapv (fn [u] {:uid u :bounds []}) (:tparams d))]
    [tps [:named (:id d) (mapv (fn [u] [:param u]) (:tparams d))]]))

(defn- call-variant [env pos d vi args expected]
  (let [decl (nth (:decls *prog*) d)
        [tps rt] (variant-sig decl)]
    (generic-call env pos tps (:payload (nth (:variants decl) vi)) rt args expected
                  (fn [irs] [:make-enum d vi irs]))))

(defn- finish-method
  "Steps 3 to 6 of 8.5 once the trait and receiver are known."
  [env pos tid midx rt rir args np expected]
  (let [trait (nth (:traits-table *prog*) tid)
        m (nth (:methods trait) midx)]
    (when-not (= (count args) (count (:params m))) (diag/fail :arity np))
    (let [rt (t/zonk rt)]
      (when-not (program/holds? *prog* rt tid) (diag/fail :unsatisfied-bound np))
      (let [sm {(:self-uid trait) rt}
            irs (mapv (fn [a pt] (check env a (t/subst-params pt sm))) args (:params m))
            ret (t/subst-params (:ret m) sm)]
        (when expected
          (when-not (t/unify expected ret) (mismatch pos)))
        [ret [:call-method tid midx rir irs]]))))

(defn- mcall [env e expected]
  (when (> (count (:args e)) 16) (diag/fail :bad-arity (:name-pos e)))
  (let [[rt rir] (infer env (:recv e))
        np (:name-pos e)
        cands (filterv #(names/method-index *prog* % (:name e))
                       (sort (program/visible-trait-ids *prog* (:mod env))))]
    (case (count cands)
      0 (diag/fail :no-method np)
      1 nil
      (diag/fail :ambig-method np))
    (let [tid (first cands)]
      (finish-method env (:pos e) tid (names/method-index *prog* tid (:name e)) rt rir (:args e) np expected))))

(defn- method-path-call [env e r expected]
  (let [[_ tid midx] r
        np (:name-pos (:callee e))
        args (:args e)]
    (when (empty? args) (diag/fail :arity np))
    (let [[rt rir] (infer env (first args))]
      (finish-method env (:pos e) tid midx rt rir (rest args) np expected))))

(defn- indirect-call [env e expected]
  (let [callee (:callee e)
        [ft cir] (infer env callee)
        ft (prune ft)]
    (when-not (and (vector? ft) (= :fn (nth ft 0))) (diag/fail :not-callable (:pos callee)))
    (when-not (= (count (:args e)) (count (nth ft 1))) (diag/fail :arity (:pos callee)))
    (let [irs (mapv (fn [a p] (check env a p)) (:args e) (nth ft 1))]
      (when expected
        (when-not (t/unify expected (nth ft 2)) (mismatch (:pos e))))
      [(nth ft 2) [:call-value cir irs]])))

(defn- do-call
  "Type a call expression; `expected` is the type to check against or nil."
  [env e expected]
  (let [callee (:callee e)
        args (:args e)]
    (when (> (count args) 16) (diag/fail :bad-arity (:pos callee)))
    (if (= :path (:e callee))
      (let [r (names/resolve-value *prog* (:mod env) callee (:locals env))
            pos (:pos e)]
        (case (first r)
          :local (indirect-call env e expected)
          :fn (let [f (nth (:fns *prog*) (second r))]
                (generic-call env pos (:tparams f) (:params f) (:ret f) args expected
                              (fn [irs] [:call-fn (second r) irs])))
          :builtin (let [b (second r)]
                     (generic-call env pos (:tparams b) (:params b) (:ret b) args expected
                                   (fn [irs] [:call-builtin (:id b) irs])))
          :variant (call-variant env pos (second r) (nth r 2) args expected)
          :method (method-path-call env e r expected)
          :type (diag/fail :bad-value-ref (:name-pos callee))))
      (indirect-call env e expected))))

;; ---------------------------------------------------------------------------
;; literals and simple forms

(def ^:private arith-ops
  {"+" [:add-i :add-f] "-" [:sub-i :sub-f] "*" [:mul-i :mul-f]
   "/" [:div-i :div-f] "%" [:mod-i nil]})

(def ^:private bit-ops
  {"&" :band "|" :bor "^" :bxor "<<" :shl ">>" :shr})

(def ^:private cmp-ops
  {"<" :lt "<=" :le ">" :gt ">=" :ge})

(defn- infer-binary [env e]
  (let [op (:op e) l (:l e) r (:r e)]
    (cond
      (contains? arith-ops op)
      (let [[lt lir] (infer env l)
            lt (prune lt)]
        (when-not (or (= lt :int) (= lt :float)) (mismatch (:pos l)))
        (when (and (= op "%") (= lt :float)) (mismatch (:pos l)))
        (let [rir (check env r lt)
              [ii fo] (get arith-ops op)]
          [lt [:binop (if (= lt :int) ii fo) lir rir]]))

      (= op "++")
      (let [[lt lir] (infer env l)
            lt (prune lt)]
        (when-not (or (= lt :str) (and (vector? lt) (= :list (nth lt 0)))) (mismatch (:pos l)))
        (let [rir (check env r lt)]
          [lt [:binop (if (= lt :str) :concat-str :concat-list) lir rir]]))

      (contains? bit-ops op)
      (let [lir (check env l :int) rir (check env r :int)]
        [:int [:binop (get bit-ops op) lir rir]])

      (contains? cmp-ops op)
      (let [[lt lir] (infer env l)
            lt (t/zonk lt)]
        (when-not (program/holds? *prog* lt program/trait-ord) (diag/fail :not-ord (:pos l)))
        (let [rir (check env r lt)]
          [:bool [:binop (get cmp-ops op) lir rir]]))

      (or (= op "==") (= op "!="))
      (let [[lt lir] (infer env l)
            lt (t/zonk lt)]
        (when-not (program/holds? *prog* lt program/trait-eq) (diag/fail :not-eq (:pos l)))
        (let [rir (check env r lt)]
          [:bool [:binop (if (= op "==") :eq :ne) lir rir]]))

      :else                              ; && ||
      (let [lir (check env l :bool) rir (check env r :bool)]
        [:bool [:binop (if (= op "&&") :and :or) lir rir]]))))

(defn- infer-unary [env e]
  (let [x (:x e)]
    (case (:op e)
      "-" (let [[ty ir] (infer env x)
                ty (prune ty)]
            (when-not (or (= ty :int) (= ty :float)) (mismatch (:pos x)))
            [ty [:unop (if (= ty :int) :neg-i :neg-f) ir]])
      "!" [:bool [:unop :not (check env x :bool)]]
      "~" [:int [:unop :bnot (check env x :int)]])))

(defn- infer-index [env e]
  (let [[at air] (infer env (:x e))
        at (prune at)]
    (cond
      (and (vector? at) (= :list (nth at 0)))
      [(nth at 1) [:index air (check env (:i e) :int)]]
      (= at :str)
      [:char [:index air (check env (:i e) :int)]]
      (and (vector? at) (= :map (nth at 0)))
      [(nth at 2) [:index air (check env (:i e) (nth at 1))]]
      :else (diag/fail :not-indexable (:pos (:x e))))))

(defn- infer-field [env e]
  (let [[ty ir] (infer env (:x e))
        ty (prune ty)]
    (when-not (and (vector? ty) (= :named (nth ty 0))
                   (= :struct (:kind (nth (:decls *prog*) (nth ty 1)))))
      (diag/fail :not-struct (:pos (:x e))))
    (let [d (nth (:decls *prog*) (nth ty 1))
          idx (first (keep-indexed (fn [i f] (when (= (:name f) (:name e)) i)) (:fields d)))]
      (when-not idx (diag/fail :unknown-field (:name-pos e)))
      [(t/subst-params (:ty (nth (:fields d) idx)) (zipmap (:tparams d) (nth ty 2)))
       [:field ir idx]])))

(defn- struct-literal [env e expected]
  (let [path (:path e)
        did (names/resolve-struct-type *prog* (:mod env) path)
        d (nth (:decls *prog*) did)
        fnames (mapv :name (:fields d))]
    (binding [t/*owner* (atom [])]
      (let [vars (mapv (fn [_] (t/fresh-var)) (:tparams d))
            ty [:named did vars]
            sm (zipmap (:tparams d) vars)]
        (when expected
          (when-not (t/unify ty expected) (mismatch (:pos path))))
        (reduce (fn [seen f]
                  (when (contains? seen (:name f)) (diag/fail :dup-field (:pos f)))
                  (when-not (some #{(:name f)} fnames) (diag/fail :unknown-field (:pos f)))
                  (conj seen (:name f)))
                #{} (:fields e))
        (let [by-name (into {} (map (juxt :name identity)) (:fields e))
              irs (reduce (fn [acc [i f]]
                            (if-let [wf (get by-name (:name f))]
                              (assoc acc (:name f) (check env (:expr wf) (t/subst-params (:ty f) sm)))
                              (diag/fail :missing-field (:pos path))))
                          {} (map-indexed vector (:fields d)))]
          (when-not (every? t/ground? @t/*owner*) (diag/fail :cannot-infer (:pos path)))
          [(t/zonk ty)
           [:make-struct did (mapv (fn [f] [(.indexOf ^java.util.List fnames (:name f)) (get irs (:name f))])
                                   (:fields e))]])))))

(defn- infer-list [env e]
  (let [elems (:elems e)]
    (when (empty? elems) (diag/fail :cannot-infer (:pos e)))
    (let [[ty ir1] (infer env (first elems))
          irs (into [ir1] (map #(check env % ty)) (rest elems))]
      [[:list ty] [:make-list irs]])))

(defn- infer-map [env e]
  (let [entries (:entries e)]
    (when (empty? entries) (diag/fail :cannot-infer (:pos e)))
    (let [[k1 v1] (first entries)
          [kt kir] (infer env k1)
          kt (t/zonk kt)]
      (when-not (program/holds? *prog* kt program/trait-key) (diag/fail :bad-key-type (:pos k1)))
      (let [[vt vir] (infer env v1)
            irs (into [[kir vir]]
                      (map (fn [[k v]] (let [ki (check env k kt)] [ki (check env v vt)])))
                      (rest entries))]
        [[:map kt vt] [:make-map irs]]))))

(defn- infer-tuple [env e]
  (when (> (count (:elems e)) 8) (diag/fail :bad-arity (:pos e)))
  (let [rs (mapv #(infer env %) (:elems e))]
    [(into [:tuple] (map first) rs) [:make-tuple (mapv second rs)]]))

;; ---------------------------------------------------------------------------
;; lambdas (10.10, 9.3)

(defn- lambda [env e expected]
  (let [params (:params e)
        pos (:pos e)
        ;; the expected function type, expanded when it is a variable
        ft (when expected
             (let [x (prune expected)]
               (cond
                 (and (vector? x) (= :fn (nth x 0)))
                 (do (when-not (= (count (nth x 1)) (count params)) (mismatch pos)) x)
                 (t/var? x)
                 (let [f [:fn (mapv (fn [_] (t/fresh-var)) params) (t/fresh-var)]]
                   (t/unify x f)
                   (when-not (= (count (nth (prune x) 1)) (count params)) (mismatch pos))
                   (prune x))
                 :else (mismatch pos))))
        ptys (mapv (fn [p i]
                     (let [ann (when (:ty p) (rtype env (:ty p)))]
                       (if ft
                         (let [a (nth (nth ft 1) i)]
                           (if ann
                             (do (when-not (t/unify a ann) (mismatch (:pos (:ty p)))) a)
                             (do (when (t/var? (prune a)) (diag/fail :cannot-infer (:pos p))) a)))
                         (or ann (diag/fail :cannot-infer (:pos p))))))
                   params (range))
        declared (when (:ret e) (rtype env (:ret e)))
        ret (if ft
              (let [r (nth ft 2)]
                (when declared (when-not (t/unify r declared) (mismatch (:pos (:ret e)))))
                r)
              declared)
        _ (reduce (fn [seen p]
                    (when (contains? seen (:name p)) (diag/fail :dup-name (:pos p)))
                    (conj seen (:name p)))
                  #{} params)
        ctx {:id (next-id!) :caps (atom [])}
        env2 (-> env (assoc :fn (:id ctx) :ctxs (conj (:ctxs env) ctx) :ret ret :in-loop false))
        bs (mapv (fn [p ty] (new-binding env2 (:name p) ty false)) params ptys)
        env3 (with-locals env2 bs)
        body (:body e)
        [rty body-ir]
        (cond
          (and ret (= :block (:e body)))
          (let [ir (check-fn-body-ir env3 body ret pos)] [ret ir])
          ret [ret (check env3 body ret)]
          :else (infer env3 body))]
    [(if ft (t/zonk ft) [:fn ptys rty])
     [:lambda {:id (:id ctx) :params bs :body body-ir :captures @(:caps ctx)}]]))

;; ---------------------------------------------------------------------------
;; if / match / blocks

(defn- infer-if [env e]
  (let [cir (check env (:c e) :bool)]
    (if-not (:else e)
      [:unit [:if cir (check env (:then e) :unit) nil]]
      (if-not (diverges? (:then e))
        (let [[ty tir] (infer env (:then e))
              eir (check env (:else e) ty)]
          [ty [:if cir tir eir]])
        (let [[_ tir] (infer env (:then e))]
          (if (diverges? (:else e))
            (let [[_ eir] (infer env (:else e))] [:unit [:if cir tir eir]])
            (let [[ty eir] (infer env (:else e))] [ty [:if cir tir eir]])))))))

(defn- check-if [env e ty]
  (let [cir (check env (:c e) :bool)]
    (if-not (:else e)
      (do (when-not (t/unify ty :unit) (mismatch (:pos e)))
          [:if cir (check env (:then e) ty) nil])
      (let [tir (check env (:then e) ty)
            eir (check env (:else e) ty)]
        [:if cir tir eir]))))

(defn- check-arm-pattern [env arm scrut-ty]
  (let [bound (atom {})
        ctx {:bound bound :mk (fn [name ty] (new-binding env name ty false))}
        tp (pat/check-pat *prog* (:mod env) ctx (:pat arm) scrut-ty)]
    [tp (vals @bound)]))

(defn- match-expr
  "Both modes: `expected` is the type to check against, or nil to synthesise."
  [env e expected]
  (let [[st sir] (infer env (:scrut e))
        st (t/zonk st)
        arms (:arms e)]
    (when (empty? arms) (diag/fail :non-exhaustive (:pos e)))
    (let [state (volatile! nil)             ; R in synthesis mode
          results
          (mapv (fn [arm]
                  (let [[tp bs] (check-arm-pattern env arm st)
                        env2 (with-locals env bs)
                        gir (when (:guard arm) (check env2 (:guard arm) :bool))
                        body (:body arm)
                        bir (cond
                              expected (check env2 body expected)
                              (nil? @state)
                              (let [[ty ir] (infer env2 body)]
                                (when-not (diverges? body) (vreset! state ty))
                                ir)
                              :else (check env2 body @state))]
                    {:pat tp :guard gir :body bir :guard? (boolean (:guard arm))}))
                arms)
          pats (mapv #(select-keys % [:pat :guard?]) results)]
      (when-let [i (pat/first-unreachable *prog* pats st)]
        (diag/fail :unreachable (:pos (:pat (nth arms i)))))
      (when-not (pat/exhaustive? *prog* pats st)
        (diag/fail :non-exhaustive (:pos e)))
      [(or expected @state :unit)
       [:match sir (mapv #(select-keys % [:pat :guard :body]) results)]])))

;; blocks ---------------------------------------------------------------------

(defn- check-stmt [env s]
  (case (:s s)
    :expr (let [[_ ir] (infer env (:expr s))] [env [:expr ir]])

    :let
    (let [ann (when (:ty s) (rtype env (:ty s)))
          [ty ir] (if ann [ann (check env (:init s) ann)] (infer env (:init s)))
          bound (atom {})
          ctx {:bound bound :mk (fn [name ty] (new-binding env name ty false))}
          tp (pat/check-pat *prog* (:mod env) ctx (:pat s) ty)]
      (when-not (pat/irrefutable? *prog* tp) (diag/fail :refutable-pattern (:pos (:pat s))))
      [(with-locals env (vals @bound)) [:let tp ir]])

    :var
    (let [ann (when (:ty s) (rtype env (:ty s)))
          [ty ir] (if ann [ann (check env (:init s) ann)] (infer env (:init s)))
          b (new-binding env (:name s) ty true)]
      [(with-locals env [b]) [:var-decl b ir]])

    :assign
    (let [target (:target s)]
      (case (:e target)
        :path
        (if (:mod target)
          (diag/fail :bad-target (:pos target))
          (let [b (get (:locals env) (:name target))]
            (when-not b (diag/fail :unknown-name (:pos target)))
            (when-not (:mutable? b) (diag/fail :assign-immutable (:pos target)))
            (when-not (== (:fn b) (:fn env)) (diag/fail :assign-captured (:pos target)))
            [env [:assign-var b (check env (:value s) (:type b))]]))
        :index
        (let [[at air] (infer env (:x target))
              at (prune at)]
          (cond
            (and (vector? at) (= :list (nth at 0)))
            (let [iir (check env (:i target) :int)
                  vir (check env (:value s) (nth at 1))]
              [env [:assign-index air iir vir]])
            (and (vector? at) (= :map (nth at 0)))
            (let [iir (check env (:i target) (nth at 1))
                  vir (check env (:value s) (nth at 2))]
              [env [:assign-index air iir vir]])
            :else (diag/fail :bad-target (:pos (:x target)))))
        (diag/fail :bad-target (:pos target))))

    :while
    (let [cir (check env (:c s) :bool)
          body (check-block-stmt (assoc env :in-loop true) (:body s))]
      [env [:while cir body]])

    :for
    (let [range? (boolean (:hi s))
          [elem src-ir hi-ir]
          (if range?
            (let [lo (check env (:iter s) :int)
                  hi (check env (:hi s) :int)]
              [:int lo hi])
            (let [[st sir] (infer env (:iter s))
                  st (prune st)]
              [(cond
                 (and (vector? st) (= :list (nth st 0))) (nth st 1)
                 (= st :str) :char
                 :else (diag/fail :not-iterable (:pos (:iter s))))
               sir nil]))
          bound (atom {})
          ctx {:bound bound :mk (fn [name ty] (new-binding env name ty false))}
          tp (pat/check-pat *prog* (:mod env) ctx (:pat s) elem)]
      (when-not (pat/irrefutable? *prog* tp) (diag/fail :refutable-pattern (:pos (:pat s))))
      (let [body (check-block-stmt (with-locals (assoc env :in-loop true) (vals @bound)) (:body s))]
        [env (if range?
               [:for-range tp src-ir hi-ir body]
               [:for-seq tp src-ir body])]))

    :return
    (let [ret (:ret env)
          e (:expr s)]
      (when-not ret (diag/fail :cannot-infer (:pos s)))
      (cond
        (nil? e)
        (do (when-not (t/unify ret :unit) (mismatch (:pos s)))
            [env [:return nil]])
        (= :unit (prune ret))
        (let [[ty ir] (infer env e)]
          (when-not (= :unit (prune ty)) (mismatch (:pos s)))
          [env [:return ir]])
        :else [env [:return (check env e ret)]]))

    :break (do (when-not (:in-loop env) (diag/fail :break-outside (:pos s))) [env [:break]])
    :continue (do (when-not (:in-loop env) (diag/fail :break-outside (:pos s))) [env [:continue]])))

(defn- check-block-stmt
  "A statement block (while/for body): the tail is synthesised and discarded."
  [env b]
  (let [[env2 sirs] (check-stmts env (:stmts b))]
    [:block (if-let [tail (:tail b)]
              (conj sirs [:expr (second (infer env2 tail))])
              sirs)
     nil]))

(defn- check-stmts [env stmts]
  (reduce (fn [[env irs] s]
            (let [[env2 ir] (check-stmt env s)]
              [env2 (conj irs ir)]))
          [env []] stmts))

(defn- infer-block [env b]
  (let [[env2 sirs] (check-stmts env (:stmts b))]
    (if-let [tail (:tail b)]
      (let [[ty ir] (infer env2 tail)] [ty [:block sirs ir]])
      [:unit [:block sirs nil]])))

(defn- check-block [env b ty]
  (let [[env2 sirs] (check-stmts env (:stmts b))]
    (if-let [tail (:tail b)]
      [:block sirs (check env2 tail ty)]
      (do (when-not (diverges? b)
            (when-not (t/unify ty :unit) (mismatch (:pos b))))
          [:block sirs nil]))))

(defn- check-fn-body-ir
  "Function/lambda body rule (11.6): `ret` is the return type."
  [env b ret pos]
  (let [[env2 sirs] (check-stmts env (:stmts b))]
    (if-let [tail (:tail b)]
      [:block sirs (check env2 tail ret)]
      (do (when-not (or (= :unit (prune ret)) (diverges? b))
            (diag/fail :missing-return pos))
          [:block sirs nil]))))

;; ---------------------------------------------------------------------------
;; infer / check dispatch

(defn infer
  "Synthesise the type of expression `e`.  Returns [type ir]."
  [env e]
  (case (:e e)
    :int [:int [:int (:v e)]]
    :float [:float [:float (:v e)]]
    :str [:str [:str (:v e)]]
    :char [:char [:char (:v e)]]
    :bool [:bool [:bool (:v e)]]
    :self (if-let [b (get (:locals env) "self")]
            (do (use-binding! env b) [(:type b) [:var b]])
            (diag/fail :self-outside (:pos e)))
    :path
    (let [r (names/resolve-value *prog* (:mod env) e (:locals env))]
      (case (first r)
        :local (let [b (second r)] (use-binding! env b) [(:type b) [:var b]])
        :variant (let [d (nth (:decls *prog*) (second r))]
                   (if (empty? (:payload (nth (:variants d) (nth r 2))))
                     (call-variant env (:pos e) (second r) (nth r 2) [] nil)
                     (diag/fail :bad-value-ref (:name-pos e))))
        (diag/fail :bad-value-ref (:name-pos e))))
    :unary (infer-unary env e)
    :binary (infer-binary env e)
    :call (do-call env e nil)
    :mcall (mcall env e nil)
    :index (infer-index env e)
    :field (infer-field env e)
    :struct-lit (struct-literal env e nil)
    :list (infer-list env e)
    :map (infer-map env e)
    :tuple (infer-tuple env e)
    :lambda (lambda env e nil)
    :if (infer-if env e)
    :match (match-expr env e nil)
    :block (infer-block env e)))

(defn- default-check [env e ty]
  (let [[s ir] (infer env e)]
    (when-not (t/unify ty s) (mismatch (:pos e)))
    ir))

(defn- check-list [env e ty]
  (let [x (prune ty)
        elem (cond
               (and (vector? x) (= :list (nth x 0))) (nth x 1)
               (t/var? x) (let [a (t/fresh-var)] (t/unify x [:list a]) a)
               :else (mismatch (:pos e)))]
    [:make-list (mapv #(check env % elem) (:elems e))]))

(defn- check-map [env e ty]
  (let [x (prune ty)
        expanded? (t/var? x)
        [k v] (cond
                (and (vector? x) (= :map (nth x 0))) [(nth x 1) (nth x 2)]
                expanded? (let [k (t/fresh-var) v (t/fresh-var)] (t/unify x [:map k v]) [k v])
                :else (mismatch (:pos e)))
        irs (mapv (fn [[ke ve]] (let [ki (check env ke k)] [ki (check env ve v)])) (:entries e))]
    (when (and expanded? (t/ground? k) (not (program/holds? *prog* (t/zonk k) program/trait-key)))
      (diag/fail :bad-key-type (:pos e)))
    [:make-map irs]))

(defn- check-tuple [env e ty]
  (when (> (count (:elems e)) 8) (diag/fail :bad-arity (:pos e)))
  (let [x (prune ty)
        n (count (:elems e))
        tys (cond
              (and (vector? x) (= :tuple (nth x 0)))
              (do (when-not (= n (dec (count x))) (mismatch (:pos e))) (vec (rest x)))
              (t/var? x) (let [ts (mapv (fn [_] (t/fresh-var)) (:elems e))]
                           (t/unify x (into [:tuple] ts)) ts)
              :else (mismatch (:pos e)))]
    [:make-tuple (mapv #(check env %1 %2) (:elems e) tys)]))

(defn check
  "Check expression `e` against `ty`.  Returns the IR."
  [env e ty]
  (case (:e e)
    :list (check-list env e ty)
    :map (check-map env e ty)
    :tuple (check-tuple env e ty)
    :lambda (second (lambda env e ty))
    :if (check-if env e ty)
    :match (second (match-expr env e ty))
    :block (check-block env e ty)
    :call (second (do-call env e ty))
    :struct-lit (second (struct-literal env e ty))
    :path (let [r (names/resolve-value *prog* (:mod env) e (:locals env))]
            (if (and (= :variant (first r))
                     (empty? (:payload (nth (:variants (nth (:decls *prog*) (second r))) (nth r 2)))))
              (second (call-variant env (:pos e) (second r) (nth r 2) [] ty))
              (default-check env e ty)))
    (default-check env e ty)))

;; ---------------------------------------------------------------------------
;; program

(defn- check-fn [f]
  (let [item (:item f)
        ctx {:id (next-id!) :caps (atom [])}
        env0 {:mod (:mod f) :tscope (:tscope f) :self (:self-ty f) :locals {}
              :fn (:id ctx) :ctxs [ctx] :ret (:ret f) :in-loop false}
        self-b (when (= :method (:kind f)) (new-binding env0 "self" (:self-ty f) false))
        pbs (mapv (fn [n ty] (new-binding env0 n ty false)) (:param-names f) (:params f))
        env (with-locals env0 (if self-b (cons self-b pbs) pbs))]
    (t/with-inference
      {:id (:id f)
       :params (if self-b (into [self-b] pbs) pbs)
       :body (check-fn-body-ir env (:body item) (:ret f) (:pos item))})))

(defn check-program
  "Type check every function body in pass-4 order.  Returns a map from
  function id to `{:id :params :body}`."
  [prog]
  (binding [*prog* prog
            *counter* (atom 0)]
    (reduce (fn [acc fid] (assoc acc fid (check-fn (nth (:fns prog) fid))))
            {} (:body-order prog))))
