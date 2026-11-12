(ns langvm.program
  "The program model: modules, namespaces, declarations and signatures
  (SPEC sections 5 to 8 and compiler pass 3).

  [[build]] performs pass 3 (declarations, imports, internal duplicates,
  signatures, impls, entry point) over the parsed modules and returns an
  immutable *program* map used by the type checker:

  * `:modules`  vector of `{:name :items :types :traits :values :imports}`
  * `:decls`    structs and enums; ids 0 and 1 are the prelude `Option`/`Result`
  * `:traits-table` ids 0, 1, 2 are the built-in `Eq`, `Ord`, `Key`
  * `:fns`      every function body: plain functions, impl methods and trait
                default methods
  * `:impls`, `:impl-index` the program-wide impl registry
  * `:builtins` the prelude functions, by name"
  (:require [langvm.diag :as diag]
            [langvm.lexer :as lexer]
            [langvm.parser :as parser]
            [langvm.types :as t]))

(set! *warn-on-reflection* true)

(def ^:const trait-eq 0)
(def ^:const trait-ord 1)
(def ^:const trait-key 2)
(def ^:const decl-option 0)
(def ^:const decl-result 1)

(def reserved-names #{"Int" "Float" "Bool" "Char" "Str" "Unit" "Self"})

(def ^:private prim-types
  {"Int" :int "Float" :float "Bool" :bool "Char" :char "Str" :str "Unit" :unit})

;; ---------------------------------------------------------------------------
;; fresh identifiers and bounds registry

(defn- new-uid! [A] (swap! (:uid @A) inc))

(defn- register-bounds! [A uid bounds]
  (swap! (:param-bounds @A) update uid (fnil into #{}) bounds))

(defn param-bounds
  "The set of trait ids bounding rigid parameter `uid`."
  [prog uid]
  (get @(:param-bounds prog) uid #{}))

;; ---------------------------------------------------------------------------
;; program construction helpers

(defn- add!
  "Append `entry` (a map) to the vector under `k`, assigning `:id`.  Returns id."
  [A k entry]
  (let [id (count (get @A k))]
    (swap! A update k conj (assoc entry :id id))
    id))

(defn- update-entry! [A k id f & args]
  (swap! A update-in [k id] #(apply f % args)))

(defn- prelude-decls [A]
  (let [t (new-uid! A) u (new-uid! A) e (new-uid! A)]
    (add! A :decls {:kind :enum :mod nil :name "Option" :pub true :tnames ["T"] :tparams [t]
                    :variants [{:name "Some" :payload [[:param t]]}
                               {:name "None" :payload []}]})
    (add! A :decls {:kind :enum :mod nil :name "Result" :pub true :tnames ["T" "E"] :tparams [u e]
                    :variants [{:name "Ok" :payload [[:param u]]}
                               {:name "Err" :payload [[:param e]]}]})))

(defn- decl [prog id] (nth (:decls prog) id))

(defn prelude-values
  "Prelude variant names -> [:variant decl vidx]."
  []
  {"Some" [:variant decl-option 0] "None" [:variant decl-option 1]
   "Ok" [:variant decl-result 0] "Err" [:variant decl-result 1]})

;; ---------------------------------------------------------------------------
;; trait satisfaction (SPEC section 7 and 8.4)

(declare holds?)

(defn- eq-holds? [prog ty assumed]
  (let [ty (t/prune ty)]
    (if (keyword? ty)
      true
      (case (nth ty 0)
        :list (recur prog (nth ty 1) assumed)
        :map (recur prog (nth ty 2) assumed)
        :tuple (every? #(eq-holds? prog % assumed) (rest ty))
        :fn false
        :param (let [b (param-bounds prog (nth ty 1))]
                 (boolean (or (b trait-eq) (b trait-key))))
        :var false
        :named (let [id (nth ty 1)]
                 (or (contains? assumed id)
                     (let [d (decl prog id)
                           m (zipmap (:tparams d) (nth ty 2))
                           assumed (conj assumed id)
                           tys (if (= :struct (:kind d))
                                 (map :ty (:fields d))
                                 (mapcat :payload (:variants d)))]
                       (every? #(eq-holds? prog (t/subst-params % m) assumed) tys))))))))

(defn- head-bindings
  "Bind the impl's head parameters against concrete type `ty`."
  [head ty]
  (let [ty (t/prune ty)]
    (if (keyword? head)
      {}
      (case (nth head 0)
        :list {(nth (nth head 1) 1) (nth ty 1)}
        :map {(nth (nth head 1) 1) (nth ty 1) (nth (nth head 2) 1) (nth ty 2)}
        :named (zipmap (map #(nth % 1) (nth head 2)) (nth ty 2))))))

(defn holds?
  "Does type `ty` satisfy trait `trait-id`?  `ty` must be ground or rigid."
  [prog ty trait-id]
  (let [ty (t/prune ty)]
    (cond
      (== trait-id trait-eq) (eq-holds? prog ty #{})
      (== trait-id trait-ord)
      (if (keyword? ty)
        (contains? #{:int :float :bool :char :str} ty)
        (and (= :param (nth ty 0)) (contains? (param-bounds prog (nth ty 1)) trait-ord)))
      (== trait-id trait-key)
      (if (keyword? ty)
        (contains? #{:int :bool :char :str} ty)
        (and (= :param (nth ty 0)) (contains? (param-bounds prog (nth ty 1)) trait-key)))
      (and (vector? ty) (= :param (nth ty 0)))
      (contains? (param-bounds prog (nth ty 1)) trait-id)
      :else
      (let [con (t/head-con ty)
            impl (when con (get (:impl-index prog) [trait-id con]))]
        (boolean
         (when impl
           (let [im (nth (:impls prog) impl)
                 m (head-bindings (:head im) ty)]
             (every? (fn [{:keys [uid bounds]}]
                       (every? #(holds? prog (get m uid) %) bounds))
                     (:tparams im)))))))))

;; ---------------------------------------------------------------------------
;; name lookup

(defn- module-of [prog mi] (nth (:modules prog) mi))

(defn lookup-trait-unqualified
  "Trait `name` as seen from module `mi` in a type position: the module's own
  traits, then the prelude's."
  [prog mi name]
  (or (when mi (get (:traits (module-of prog mi)) name))
      (get {"Eq" trait-eq "Ord" trait-ord "Key" trait-key} name)))

(defn visible-trait-ids
  "Ids of every user trait visible in module `mi` (own plus `pub` traits of
  imported modules)."
  [prog mi]
  (let [m (module-of prog mi)]
    (into (set (vals (:traits m)))
          (for [[_ im] (:imports m)
                :when (not= im mi)
                [_ tid] (:traits (module-of prog im))
                :when (:pub (nth (:traits-table prog) tid))]
            tid))))

(defn find-visible-trait
  "Trait named `name` for a `Tr::m` path in module `mi` (SPEC 5.4)."
  [prog mi name]
  (or (get (:traits (module-of prog mi)) name)
      (some (fn [[_ im]]
              (when (not= im mi)
                (let [tid (get (:traits (module-of prog im)) name)]
                  (when (and tid (:pub (nth (:traits-table prog) tid))) tid))))
            (sort-by key (:imports (module-of prog mi))))
      (get {"Eq" trait-eq "Ord" trait-ord "Key" trait-key} name)))

;; ---------------------------------------------------------------------------
;; type resolution

(defn- resolve-in-module
  "Resolve the qualified name `mod::name` in namespace `ns-key` of module
  `mi`.  `unknown` is the error kind for a missing item."
  [prog mi {:keys [mod mod-pos name name-pos]} ns-key unknown]
  (let [im (when mi (get (:imports (module-of prog mi)) mod))]
    (when-not im (diag/fail :unknown-module mod-pos))
    (let [target (module-of prog im)
          item (get (get target ns-key) name)]
      (when-not item (diag/fail unknown name-pos))
      (when (and (not= im mi)
                 (not (:pub (case ns-key
                              :types (decl prog item)
                              :traits (nth (:traits-table prog) item)))))
        (diag/fail :not-public name-pos))
      item)))

(defn resolve-trait-ref
  "Resolve a trait reference AST to a trait id."
  [prog mi ref]
  (if (:mod ref)
    (resolve-in-module prog mi ref :traits :unknown-trait)
    (or (lookup-trait-unqualified prog mi (:name ref))
        (diag/fail :unknown-trait (:name-pos ref)))))

(declare resolve-type)

(defn- resolve-type-args [prog env args]
  (mapv #(resolve-type prog env %) args))

(defn resolve-type
  "Resolve a written type (AST) to a semantic type.  `env` is
  `{:mod module-index-or-nil :tscope {name type} :self type-or-nil}`."
  [prog env ty]
  (case (:ty ty)
    :list [:list (resolve-type prog env (:elem ty))]
    :map (let [k (resolve-type prog env (:key ty))
               v (resolve-type prog env (:val ty))]
           (when-not (holds? prog k trait-key) (diag/fail :bad-key-type (:pos ty)))
           [:map k v])
    :tuple (do (when (> (count (:elems ty)) 8) (diag/fail :bad-arity (:pos ty)))
               (into [:tuple] (map #(resolve-type prog env %) (:elems ty))))
    :fn (do (when (> (count (:params ty)) 16) (diag/fail :bad-arity (:pos ty)))
            (let [ps (mapv #(resolve-type prog env %) (:params ty))
                  r (if (:ret ty) (resolve-type prog env (:ret ty)) :unit)]
              [:fn ps r]))
    :path
    (let [{:keys [mod name args pos]} ty
          nargs (count args)
          no-args! (fn [t] (when (pos? nargs) (diag/fail :arity-type pos)) t)
          named (fn [id]
                  (let [d (decl prog id)]
                    (when (not= nargs (count (:tnames d))) (diag/fail :arity-type pos))
                    [:named id (resolve-type-args prog env args)]))]
      (if mod
        (named (resolve-in-module prog (:mod env) ty :types :unknown-type))
        (let [mi (:mod env)]
          (cond
            (contains? (:tscope env) name) (no-args! (get (:tscope env) name))
            (= name "Self") (if (:self env)
                              (no-args! (:self env))
                              (diag/fail :self-outside pos))
            (contains? prim-types name) (no-args! (get prim-types name))
            (and mi (get (:types (module-of prog mi)) name)) (named (get (:types (module-of prog mi)) name))
            (= name "Option") (named decl-option)
            (= name "Result") (named decl-result)
            :else (diag/fail :unknown-type (:name-pos ty))))))))

;; ---------------------------------------------------------------------------
;; pass 3

(defn- modules-items [A] (map-indexed vector (map :items (:modules @A))))

(defn- ns-put!
  "Enter `name` into namespace `ns-key` of module `mi`, or fail `dup-name`."
  [A mi ns-key name value p]
  (when (contains? (get-in @A [:modules mi ns-key]) name)
    (diag/fail :dup-name p))
  (swap! A assoc-in [:modules mi ns-key name] value))

(defn- pass-declare [A]
  (doseq [[mi items] (modules-items A)
          item items]
    (case (:i item)
      :fn (let [id (add! A :fns {:kind :fn :mod mi :name (:name item) :pub (:pub item)
                                 :item item})]
            (ns-put! A mi :values (:name item) [:fn id] (:name-pos item)))
      (:struct :enum)
      (do
        (when (reserved-names (:name item)) (diag/fail :reserved-name (:name-pos item)))
        (let [tparams (mapv (fn [_] (new-uid! A)) (:tparams item))
              id (add! A :decls {:kind (:i item) :mod mi :name (:name item) :pub (:pub item)
                                 :tnames (mapv :name (:tparams item)) :tparams tparams
                                 :item item})]
          (ns-put! A mi :types (:name item) id (:name-pos item))
          (when (= :enum (:i item))
            (doseq [[vi v] (map-indexed vector (:variants item))]
              (ns-put! A mi :values (:name v) [:variant id vi] (:pos v))))))
      :trait
      (do
        (when (reserved-names (:name item)) (diag/fail :reserved-name (:name-pos item)))
        (let [id (add! A :traits-table {:kind :trait :mod mi :name (:name item) :pub (:pub item)
                                        :item item})]
          (ns-put! A mi :traits (:name item) id (:name-pos item))))
      nil)))

(defn- pass-imports [A]
  (doseq [[mi items] (modules-items A)
          item items
          :when (= :use (:i item))]
    (let [im (get (:mod-index @A) (:name item))]
      (when-not im (diag/fail :unknown-module (:name-pos item)))
      (let [bound (or (:alias item) (:name item))
            bp (if (:alias item) (:alias-pos item) (:name-pos item))]
        (ns-put! A mi :imports bound im bp)))))

(defn- check-dups [names-with-pos]
  (reduce (fn [seen [n p]]
            (when (contains? seen n) (diag/fail :dup-name p))
            (conj seen n))
          #{} names-with-pos))

(defn- pass-dups [A]
  (doseq [[_ items] (modules-items A)
          item items]
    (when-let [tps (:tparams item)]
      (check-dups (map (juxt :name :pos) tps)))
    (case (:i item)
      :struct (check-dups (map (juxt :name :pos) (:fields item)))
      :fn (check-dups (map (juxt :name :pos) (:params item)))
      (:trait :impl) (do (check-dups (map (juxt :name :name-pos) (:methods item)))
                         (doseq [m (:methods item)]
                           (check-dups (map (juxt :name :pos) (:params m)))))
      nil)))

(defn- make-tparams
  "Allocate rigid parameters for generic parameter ASTs; returns
  `{:tparams [{:uid :name}] :tscope {name type}}`."
  [A tps]
  (let [ps (mapv (fn [tp] {:uid (new-uid! A) :name (:name tp) :ast tp}) tps)]
    {:tparams ps
     :tscope (into {} (map (fn [p] [(:name p) [:param (:uid p)]]) ps))}))

(defn- resolve-bounds!
  "Resolve and register the bounds of each generic parameter; returns the
  tparams with `:bounds` filled."
  [A mi tparams]
  (let [prog @A]
    (mapv (fn [p]
            (let [bs (mapv #(resolve-trait-ref prog mi %) (:bounds (:ast p)))]
              (register-bounds! A (:uid p) bs)
              (-> p (assoc :bounds bs) (dissoc :ast))))
          tparams)))

(defn- resolve-sig [prog env params ret]
  [(mapv #(resolve-type prog env (:ty %)) params)
   (if ret (resolve-type prog env ret) :unit)])

(defn- pass-signatures [A]
  (doseq [[mi items] (modules-items A)
          item items]
    (case (:i item)
      :fn
      (let [id (get-in @A [:modules mi :values (:name item) 1])
            {:keys [tparams tscope]} (make-tparams A (:tparams item))
            tparams (resolve-bounds! A mi tparams)
            env {:mod mi :tscope tscope :self nil}
            [ptys ret] (resolve-sig @A env (:params item) (:ret item))]
        (update-entry! A :fns id assoc :tparams tparams :tscope tscope :params ptys :ret ret
                       :param-names (mapv :name (:params item)))
        (swap! A update :body-order conj id))

      :struct
      (let [id (get-in @A [:modules mi :types (:name item)])
            d (decl @A id)
            tscope (zipmap (:tnames d) (map (fn [u] [:param u]) (:tparams d)))
            env {:mod mi :tscope tscope :self nil}
            fields (mapv (fn [f] {:name (:name f) :ty (resolve-type @A env (:ty f))}) (:fields item))]
        (update-entry! A :decls id assoc :fields fields))

      :enum
      (let [id (get-in @A [:modules mi :types (:name item)])
            d (decl @A id)
            tscope (zipmap (:tnames d) (map (fn [u] [:param u]) (:tparams d)))
            env {:mod mi :tscope tscope :self nil}
            variants (mapv (fn [v] {:name (:name v)
                                    :payload (mapv #(resolve-type @A env %) (:payload v))})
                           (:variants item))]
        (update-entry! A :decls id assoc :variants variants))

      :trait
      (let [id (get-in @A [:modules mi :traits (:name item)])
            self-uid (new-uid! A)
            self-ty [:param self-uid]
            _ (register-bounds! A self-uid [id])
            env {:mod mi :tscope {} :self self-ty}
            methods (mapv (fn [m]
                            (let [[ptys ret] (resolve-sig @A env (:params m) (:ret m))
                                  fid (when (:body m)
                                        (add! A :fns {:kind :method :mod mi :name (:name m)
                                                      :item m :tparams [] :tscope {}
                                                      :self-ty self-ty :params ptys :ret ret
                                                      :param-names (mapv :name (:params m))
                                                      :trait id}))]
                              (when fid (swap! A update :body-order conj fid))
                              {:name (:name m) :params ptys :ret ret :default fid :pos (:pos m)}))
                          (:methods item))]
        (update-entry! A :traits-table id assoc :self-uid self-uid :methods methods))

      :impl
      (let [{:keys [tparams tscope]} (make-tparams A (:tparams item))
            tparams (resolve-bounds! A mi tparams)
            trait-id (resolve-trait-ref @A mi (:trait item))
            head (resolve-type @A {:mod mi :tscope tscope :self nil} (:head item))
            env {:mod mi :tscope tscope :self head}
            impl-id (add! A :impls {:mod mi :trait trait-id :head head :tparams tparams
                                    :item item :tscope tscope})
            methods (mapv (fn [m]
                            (let [[ptys ret] (resolve-sig @A env (:params m) (:ret m))
                                  fid (add! A :fns {:kind :method :mod mi :name (:name m)
                                                    :item m :tparams tparams :tscope tscope
                                                    :self-ty head :params ptys :ret ret
                                                    :param-names (mapv :name (:params m))
                                                    :impl impl-id})]
                              (swap! A update :body-order conj fid)
                              {:name (:name m) :fn fid :params ptys :ret ret :pos (:name-pos m)}))
                          (:methods item))]
        (update-entry! A :impls impl-id assoc :methods methods))
      nil)))

(defn- valid-head?
  "Is the resolved impl head `head` a primitive, `[P]`, `#[P: Q]` or
  `Name<distinct params>` over the impl's own parameters?"
  [head uids]
  (let [param? (fn [x] (and (vector? x) (= :param (nth x 0)) (contains? uids (nth x 1))))
        distinct-params? (fn [xs] (and (every? param? xs) (apply distinct? (map #(nth % 1) xs))))]
    (cond
      (keyword? head) true
      :else
      (case (nth head 0)
        :list (param? (nth head 1))
        :map (distinct-params? [(nth head 1) (nth head 2)])
        :named (or (empty? (nth head 2)) (distinct-params? (nth head 2)))
        false))))

(defn- pass-impls [A]
  (doseq [[_ items] (modules-items A)
          item items
          :when (= :impl (:i item))]
    (let [prog @A
          im (first (filter #(identical? item (:item %)) (:impls prog)))
          tr (:trait im)]
      (when (<= tr trait-key) (diag/fail :builtin-trait-impl (:pos item)))
      (let [uids (set (map :uid (:tparams im)))]
        (when-not (valid-head? (:head im) uids)
          (diag/fail :bad-impl-head (:pos (:head item))))
        (doseq [p (:tparams im)]
          (when-not (t/mentions-param? (:head im) (:uid p))
            (diag/fail :unused-param (:pos (first (filter #(= (:name p) (:name %)) (:tparams item)))))))
        (let [con (t/head-con (:head im))
              k [tr con]]
          (when (contains? (:impl-index prog) k) (diag/fail :dup-impl (:pos item)))
          (swap! A assoc-in [:impl-index k] (:id im))
          (let [trait (nth (:traits-table prog) tr)
                defined (set (map :name (:methods im)))]
            (doseq [tm (:methods trait)]
              (when (and (not (:default tm)) (not (contains? defined (:name tm))))
                (diag/fail :missing-method (:pos item))))
            (doseq [m (:methods im)]
              (let [tm (first (filter #(= (:name m) (:name %)) (:methods trait)))]
                (when-not tm (diag/fail :extra-method (:pos m)))
                (let [sm {(:self-uid trait) (:head im)}]
                  (when-not (and (= (count (:params m)) (count (:params tm)))
                                 (= (:params m) (mapv #(t/subst-params % sm) (:params tm)))
                                 (= (:ret m) (t/subst-params (:ret tm) sm)))
                    (diag/fail :sig-mismatch (:pos m))))))))))))

(defn- pass-main [A]
  (let [prog @A
        mi (get (:mod-index prog) "main")
        v (when mi (get (:values (module-of prog mi)) "main"))
        f (when (and v (= :fn (first v))) (nth (:fns prog) (second v)))]
    (when-not (and f (empty? (:tparams f)) (empty? (:params f)) (= :unit (:ret f)))
      (diag/fail :no-main (diag/pos 1 1)))
    (swap! A assoc :main (:id f))))

(defn- load-builtins
  "Parse and resolve the prelude function signatures.  `sigs` is a vector of
  `[name signature-text]`."
  [A sigs]
  (let [prog @A]
    (swap! A assoc :builtins
           (into {}
                 (map-indexed
                  (fn [id [name sig]]
                    (let [item (parser/parse-fn-item (lexer/lex [(str "fn " sig " {}")]))
                          {:keys [tparams tscope]} (make-tparams A (:tparams item))
                          tparams (resolve-bounds! A nil tparams)
                          env {:mod nil :tscope tscope :self nil}
                          [ptys ret] (resolve-sig prog env (:params item) (:ret item))]
                      [name {:id id :name name :tparams tparams :params ptys :ret ret}]))
                  sigs)))))

(defn build
  "Run pass 3 over `modules` (vector of `{:name :items}`), with the built-in
  function signatures `sigs`.  Returns the immutable program map."
  [modules sigs]
  (let [A (atom {:modules (vec (map-indexed (fn [i m] (assoc m :idx i :types {} :traits {}
                                                              :values {} :imports {}))
                                            modules))
                 :mod-index (into {} (map-indexed (fn [i m] [(:name m) i]) modules))
                 :decls [] :traits-table [] :fns [] :impls [] :impl-index {}
                 :body-order []
                 :uid (atom 0) :param-bounds (atom {})})]
    (prelude-decls A)
    (swap! A assoc :traits-table
           [{:id 0 :kind :builtin :name "Eq" :pub true :methods []}
            {:id 1 :kind :builtin :name "Ord" :pub true :methods []}
            {:id 2 :kind :builtin :name "Key" :pub true :methods []}])
    (load-builtins A sigs)
    (pass-declare A)
    (pass-imports A)
    (pass-dups A)
    (pass-signatures A)
    (pass-impls A)
    (pass-main A)
    @A))
