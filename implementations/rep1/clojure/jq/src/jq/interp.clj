(ns jq.interp
  "The evaluator. A syntax tree (see [[jq.parser]]) is compiled once into a
  tree of closures; running the closure tree is the tree-walking interpretation.

  A compiled filter is `(fn [env input emit])`:
  - `env` is the persistent variable environment (map of name to value),
  - `input` is the value `.`,
  - `emit` is called once per output value, in jq's order.

  Evaluation is push-based: outputs are delivered to `emit` as soon as they
  are produced, so results preceding an error have already been delivered when
  the error (an exception, see [[jq.value/jq-error]]) unwinds the stack."
  (:require [jq.value :as v :refer [jq-error fail]]
            [jq.ops :as ops]
            [jq.builtins :as builtins])
  (:import [java.util ArrayList]
           [clojure.lang ExceptionInfo]))

(declare compile-node)

(def ^:private skip (Object.))

(defn- each [coll f] (reduce (fn [_ x] (f x) nil) nil coll))

(defn- tolerant
  "Applies `(f x)`, returning `skip` instead of raising a jq error."
  [f x]
  (try (f x)
       (catch ExceptionInfo e (if (v/jq-error? e) skip (throw e)))))

(defn- compile-try
  "`try`: outputs of `f` up to the first error, which is swallowed. Errors
  raised downstream (inside `emit`) are not ours: they are wrapped in a marker
  while crossing this frame and unwrapped again on the way out."
  [f]
  (fn [env in emit]
    (let [owner (Object.)]
      (try
        (f env in (fn [x]
                    (try (emit x)
                         (catch ExceptionInfo e
                           (if (v/jq-error? e)
                             (throw (ex-info "downstream" {::type :pass ::owner owner ::err e}))
                             (throw e))))))
        (catch ExceptionInfo e
          (let [d (ex-data e)]
            (cond (= :error (::v/type d)) nil
                  (and (= :pass (::type d)) (identical? owner (::owner d))) (throw (::err d))
                  :else (throw e))))))))

(defn- const-node? [node] (= :literal (:op node)))

(defn- compile-index [{:keys [term idx opt]}]
  (let [tf (compile-node term)
        step (fn [emit t k]
               (let [r (if opt (tolerant (fn [_] (ops/index t k)) nil) (ops/index t k))]
                 (when-not (identical? r skip) (emit r))))]
    (if (const-node? idx)
      (let [k (:v idx)]
        (fn [env in emit] (tf env in (fn [t] (step emit t k)))))
      (let [kf (compile-node idx)]
        (fn [env in emit]
          (kf env in (fn [k] (tf env in (fn [t] (step emit t k))))))))))

(defn- compile-iterate [{:keys [term opt]}]
  (let [tf (compile-node term)]
    (fn [env in emit]
      (tf env in (fn [t]
                   (let [c (if opt (tolerant ops/elements t) (ops/elements t))]
                     (when-not (identical? c skip) (each c emit))))))))

(def ^:private emit-nil (fn [_env _in emit] (emit nil)))

(defn- compile-slice [{:keys [term from to opt]}]
  (let [tf (compile-node term)
        ff (if from (compile-node from) emit-nil)
        gf (if to (compile-node to) emit-nil)]
    (fn [env in emit]
      (ff env in
          (fn [a]
            (gf env in
                (fn [b]
                  (tf env in
                      (fn [t]
                        (let [r (if opt
                                  (tolerant (fn [_] (ops/slice t a b)) nil)
                                  (ops/slice t a b))]
                          (when-not (identical? r skip) (emit r))))))))))))

(defn- compile-object [{:keys [entries]}]
  (let [entries (mapv (fn [[k vn]] [(compile-node k) (compile-node vn)]) entries)
        n (count entries)]
    (fn [env in emit]
      (letfn [(go [i obj]
                (if (== i n)
                  (emit obj)
                  (let [[kf vf] (nth entries i)]
                    (kf env in
                        (fn [k]
                          (when-not (string? k)
                            (fail (str "Object keys must be strings")))
                          (vf env in (fn [x] (go (inc i) (v/obj-assoc obj k x)))))))))]
        (go 0 v/empty-obj)))))

(defn- compile-reduce [{:keys [src name init update]}]
  (let [sf (compile-node src) inf (compile-node init) uf (compile-node update)]
    (fn [env in emit]
      (inf env in
           (fn [init-val]
             (let [acc (volatile! init-val)]
               (sf env in
                   (fn [x]
                     (let [env' (assoc env name x)
                           last-out (volatile! nil)]
                       (uf env' @acc (fn [o] (vreset! last-out o)))
                       (vreset! acc @last-out))))
               (emit @acc)))))))

(defn- compile-binop [{:keys [f l r]}]
  (let [opf (ops/binary-ops f)
        lf (compile-node l)]
    (if (const-node? r)
      (let [b (:v r)] (fn [env in emit] (lf env in (fn [a] (emit (opf a b))))))
      (let [rf (compile-node r)]
        (fn [env in emit]
          (rf env in (fn [b] (lf env in (fn [a] (emit (opf a b)))))))))))

(defn- compile-node
  "Compiles a syntax tree node to a filter function."
  [node]
  (case (:op node)
    :identity (fn [_env in emit] (emit in))
    :literal (let [x (:v node) x (if (number? x) (double x) x)] (fn [_env _in emit] (emit x)))
    :var (let [name (:name node)]
           (fn [env _in emit]
             (let [x (get env name ::unbound)]
               (when (identical? x ::unbound) (throw (ex-info (str "$" name " is not defined") {:type :jq/error-unbound})))
               (emit x))))
    :paren (compile-node (:e node))
    :neg (let [f (compile-node (:e node))]
           (fn [env in emit] (f env in (fn [x] (emit (ops/negate x))))))
    :pipe (let [lf (compile-node (:l node)) rf (compile-node (:r node))]
            (fn [env in emit] (lf env in (fn [x] (rf env x emit)))))
    :comma (let [lf (compile-node (:l node)) rf (compile-node (:r node))]
             (fn [env in emit] (lf env in emit) (rf env in emit)))
    :binop (compile-binop node)
    :and (let [lf (compile-node (:l node)) rf (compile-node (:r node))]
           (fn [env in emit]
             (lf env in (fn [a]
                          (if a
                            (rf env in (fn [b] (emit (v/truthy? b))))
                            (emit false))))))
    :or (let [lf (compile-node (:l node)) rf (compile-node (:r node))]
          (fn [env in emit]
            (lf env in (fn [a]
                         (if a
                           (emit true)
                           (rf env in (fn [b] (emit (v/truthy? b)))))))))
    :array (if-let [e (:e node)]
             (let [f (compile-node e)]
               (fn [env in emit]
                 (let [out (ArrayList.)]
                   (f env in (fn [x] (.add out x)))
                   (emit (vec out)))))
             (fn [_env _in emit] (emit [])))
    :object (compile-object node)
    :if (let [cf (compile-node (:cond node))
              tf (compile-node (:then node))
              ef (if (:else node) (compile-node (:else node)) (fn [_env in emit] (emit in)))]
          (fn [env in emit]
            (cf env in (fn [c] (if c (tf env in emit) (ef env in emit))))))
    :bind (let [sf (compile-node (:src node)) bf (compile-node (:body node)) name (:name node)]
            (fn [env in emit]
              (sf env in (fn [x] (bf (assoc env name x) in emit)))))
    :reduce (compile-reduce node)
    :index (compile-index node)
    :iterate (compile-iterate node)
    :slice (compile-slice node)
    :try (compile-try (compile-node (:e node)))
    :call (builtins/compile-call (:name node) (mapv compile-node (:args node)))))

(defn compile-ast
  "Compiles a syntax tree to a filter function `(fn [env input emit])`."
  [ast]
  (compile-node ast))
