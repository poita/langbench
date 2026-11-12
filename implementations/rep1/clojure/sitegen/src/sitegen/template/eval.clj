(ns sitegen.template.eval
  "The tree-walking interpreter of the template language: scopes, statements,
  expressions, macros, includes and block inheritance."
  (:require [sitegen.template.filters :as filters]
            [sitegen.template.parser :as parser]
            [sitegen.template.value :as v]
            [sitegen.mutable :refer [defmutable]])
  (:import (java.util ArrayList HashMap LinkedHashMap List Map)
           (java.util.concurrent ConcurrentHashMap)
           (sitegen.template.value Macro SuperFn)))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Environment, scopes, render state

(defn make-env
  "Creates a template environment.  `loader` is a function from a template
  name to its source text, or nil when no such template exists.  Each template
  is parsed and checked at most once."
  [loader]
  {:loader loader :cache (ConcurrentHashMap.)})

(deftype Scope [^HashMap vars parent])

(defn- new-scope ^Scope [parent] (Scope. (HashMap.) parent))

(def ^:private missing (Object.))

(defn- lookup [^Scope scope ^String name]
  (loop [^Scope s scope]
    (if s
      (let [x (.getOrDefault ^HashMap (.vars s) name missing)]
        (if (identical? x missing)
          (recur (.parent s))
          x))
      (if (= name "range") v/range-fn v/undefined))))

(defn- bind! [^Scope scope ^String name value]
  (.put ^HashMap (.vars scope) name value))

;; The state of one rendering of one template: its environment, the block
;; chains (name -> list of bodies, most derived first) and its template scope.
(defmutable RState "rs-" [env chains tscope])

(defn- load-template
  "Loads (parses and checks) the template `name`, throwing a `template` error
  when it does not exist."
  [env ^String name]
  (let [^ConcurrentHashMap cache (:cache env)]
    (or (.get cache name)
        (let [src ((:loader env) name)]
          (when (nil? src) (v/error! :template (str "no template named " name)))
          (let [tpl (parser/parse-template src)]
            (.putIfAbsent cache name tpl)
            tpl)))))

(defn- template-name [x]
  (cond
    (string? x) x
    (v/undefined? x) (v/error! :undefined "template name is undefined")
    :else (v/error! :type "template name must be a string")))

;; ---------------------------------------------------------------------------
;; Expressions

(declare eval-expr exec-nodes render-block-entry)

(defn- compare-op [op a b]
  (case op
    "==" (v/equals? a b)
    "!=" (not (v/equals? a b))
    "<" (v/less? a b)
    "<=" (v/less-equal? a b)
    ">" (v/greater? a b)
    ">=" (v/greater-equal? a b)
    "in" (v/contains-value? a b)
    "not in" (not (v/contains-value? a b))))

(defn- binary-op [op a b]
  (case op
    :add (v/add a b)
    :sub (v/subtract a b)
    :mul (v/multiply a b)
    :div (v/divide a b)
    :floordiv (v/floor-divide a b)
    :mod (v/modulo a b)
    :pow (v/power a b)
    :concat (v/concat-str a b)))

(defn- call-range [args kwargs]
  (when (seq kwargs) (v/error! :type "range takes no keyword arguments"))
  (let [n (count args)]
    (when (or (zero? n) (> n 3)) (v/error! :type "range takes 1 to 3 arguments"))
    (let [ints (mapv (fn [a]
                       (cond
                         (v/undefined? a) (v/error! :undefined "range argument is undefined")
                         (instance? Long a) a
                         (instance? Boolean a) (if ^boolean a 1 0)
                         :else (v/error! :type "range arguments must be integers")))
                     args)
          [start stop step] (case n
                              1 [0 (ints 0) 1]
                              2 [(ints 0) (ints 1) 1]
                              3 [(ints 0) (ints 1) (ints 2)])]
      (when (zero? (long step)) (v/error! :type "range step must not be zero"))
      (vec (range start stop step)))))

(defn- call-macro [^Macro m args kwargs]
  (let [params (.params m)
        scope (new-scope (.scope m))
        vars ^HashMap (.vars scope)
        nparams (count params)
        nargs (count args)]
    (when (> nargs nparams) (v/error! :type "too many arguments for macro"))
    (dotimes [i nargs]
      (.put vars (first (nth params i)) (nth args i)))
    (doseq [[k val] kwargs]
      (let [idx (first (keep-indexed (fn [i [p _]] (when (= p k) i)) params))]
        (when (or (nil? idx) (< (long idx) nargs) (.containsKey vars k))
          (v/error! :type (str "bad keyword argument " k)))
        (.put vars k val)))
    (doseq [[p default] params]
      (when-not (.containsKey vars p)
        (.put vars p (if default (eval-expr (.state m) scope default) v/undefined))))
    (let [sb (StringBuilder.)]
      (exec-nodes (.state m) scope (.body m) sb)
      (.toString sb))))

(defn- call-super [^SuperFn f args kwargs]
  (when (or (seq args) (seq kwargs)) (v/error! :type "super() takes no arguments"))
  (let [rs (.state f)
        ^ArrayList chain (.get ^HashMap (rs-chains rs) (.block-name f))
        next-idx (inc (long (.index f)))]
    (if (< next-idx (.size chain))
      (let [sb (StringBuilder.)]
        (render-block-entry rs (.block-name f) next-idx sb)
        (.toString sb))
      (v/error! :undefined "no parent block for super()"))))

(defn- eval-call [rs scope e]
  (let [[_ callee pos kws] e
        f (eval-expr rs scope callee)
        args (mapv #(eval-expr rs scope %) pos)
        kwargs (mapv (fn [[k x]] [k (eval-expr rs scope x)]) kws)]
    (cond
      (instance? Macro f) (call-macro f args kwargs)
      (identical? f v/range-fn) (call-range args kwargs)
      (instance? SuperFn f) (call-super f args kwargs)
      (v/undefined? f) (v/error! :undefined "calling an undefined value")
      :else (v/error! :type "value is not callable"))))

(defn- eval-expr [rs ^Scope scope e]
  (case (nth e 0)
    :lit (nth e 1)
    :name (lookup scope (nth e 1))
    :attr (v/get-item (eval-expr rs scope (nth e 1)) (nth e 2))
    :sub (let [a (eval-expr rs scope (nth e 1))
               k (eval-expr rs scope (nth e 2))]
           (v/get-item a k))
    :call (eval-call rs scope e)
    :filter (let [x (eval-expr rs scope (nth e 1))
                  args (mapv #(eval-expr rs scope %) (nth e 3))]
              (filters/apply-filter (nth e 2) x args))
    :defined (let [x (eval-expr rs scope (nth e 1))]
               (if (nth e 2) (v/undefined? x) (not (v/undefined? x))))
    :neg (v/negate (eval-expr rs scope (nth e 1)))
    :not (not (v/truthy? (eval-expr rs scope (nth e 1))))
    :bin (let [a (eval-expr rs scope (nth e 2))
               b (eval-expr rs scope (nth e 3))]
           (binary-op (nth e 1) a b))
    :and (let [a (eval-expr rs scope (nth e 1))]
           (if (v/truthy? a) (eval-expr rs scope (nth e 2)) a))
    :or (let [a (eval-expr rs scope (nth e 1))]
          (if (v/truthy? a) a (eval-expr rs scope (nth e 2))))
    :cmp (loop [left (eval-expr rs scope (nth e 1))
                ops (seq (nth e 2))]
           (if-let [[[op operand] & more] ops]
             (let [right (eval-expr rs scope operand)]
               (if (compare-op op left right)
                 (recur right more)
                 false))
             true))
    :list (mapv #(eval-expr rs scope %) (nth e 1))))

;; ---------------------------------------------------------------------------
;; Statements

(defn- exec-for [rs ^Scope scope node ^StringBuilder out]
  (let [^List coll (v/sequence-view (eval-expr rs scope (:iter node)))
        n (.size coll)
        var ^String (:var node)]
    (if (zero? n)
      (when-let [else-body (:else node)] (exec-nodes rs scope else-body out))
      (dotimes [i n]
        (let [s (new-scope scope)
              loop-info (LinkedHashMap.)]
          (.put loop-info "index" (long (inc i)))
          (.put loop-info "index0" (long i))
          (.put loop-info "first" (zero? i))
          (.put loop-info "last" (== i (dec n)))
          (.put loop-info "length" (long n))
          (bind! s var (.get coll i))
          (bind! s "loop" loop-info)
          (exec-nodes rs s (:body node) out))))))

(defn- block-chain ^ArrayList [rs name]
  (.get ^HashMap (rs-chains rs) name))

(defn- render-block-entry
  "Renders entry `idx` of block `name`'s chain into `out`."
  [rs name idx ^StringBuilder out]
  (let [body (.get (block-chain rs name) (int idx))
        scope (new-scope (rs-tscope rs))]
    (bind! scope "super" (SuperFn. rs name idx))
    (exec-nodes rs scope body out)))

(defn- make-chains
  "Block chains holding only the template's own blocks."
  ^HashMap [tpl]
  (let [chains (HashMap.)]
    (doseq [^java.util.Map$Entry e (.entrySet ^Map (:blocks tpl))]
      (let [l (ArrayList.)]
        (.add l (.getValue e))
        (.put chains (.getKey e) l)))
    chains))

(declare run-template)

(defn- exec-node [rs ^Scope scope node ^StringBuilder out]
  (case (:t node)
    :text (.append out ^String (:s node))
    :print (.append out (v/to-str (eval-expr rs scope (:e node))))
    :if (loop [branches (seq (:branches node))]
          (if-let [[[c body] & more] branches]
            (if (v/truthy? (eval-expr rs scope c))
              (exec-nodes rs scope body out)
              (recur more))
            (when-let [else-body (:else node)]
              (exec-nodes rs scope else-body out))))
    :for (exec-for rs scope node out)
    :set (bind! scope (:name node) (eval-expr rs scope (:e node)))
    :macro (bind! scope (:name node) (Macro. (:name node) (:params node) (:body node) scope rs))
    :include (let [name (template-name (eval-expr rs scope (:e node)))
                   tpl (load-template (rs-env rs) name)
                   tscope (new-scope scope)
                   rs2 (->RState (rs-env rs) (make-chains tpl) tscope)]
               (run-template rs2 tpl out))
    :block (render-block-entry rs (:name node) 0 out)
    :extends nil))

(defn- exec-nodes [rs scope nodes out]
  (let [^List nodes nodes
        n (.size nodes)]
    (loop [i 0]
      (when (< i n)
        (exec-node rs scope (.get nodes i) out)
        (recur (inc i))))))

(defn- exec-top
  "Executes the top level of a template body.  Once an `extends` tag has run,
  only `set` and `macro` statements still take effect.  Returns the parent
  template when `extends` ran, else nil."
  [rs ^Scope scope nodes out]
  (let [n (count nodes)]
    (loop [i 0 parent nil]
      (if (< i n)
        (let [node (nth nodes i)
              t (:t node)]
          (cond
            (nil? parent)
            (if (= t :extends)
              (let [name (template-name (eval-expr rs scope (:e node)))
                    p (load-template (rs-env rs) name)
                    ^HashMap chains (rs-chains rs)]
                (doseq [^java.util.Map$Entry e (.entrySet ^Map (:blocks p))]
                  (let [^ArrayList chain (or (.get chains (.getKey e))
                                             (let [l (ArrayList.)] (.put chains (.getKey e) l) l))]
                    (.add chain (.getValue e))))
                (recur (inc i) p))
              (do (exec-node rs scope node out)
                  (recur (inc i) nil)))

            (or (= t :set) (= t :macro))
            (do (exec-node rs scope node (StringBuilder.))
                (recur (inc i) parent))

            :else (recur (inc i) parent)))
        parent))))

(defn- run-template
  "Runs `tpl` (and its chain of parents) in the template scope of `rs`."
  [rs tpl out]
  (let [scope (rs-tscope rs)]
    (loop [tpl tpl]
      (when-let [parent (exec-top rs scope (:body tpl) out)]
        (recur parent)))))

;; ---------------------------------------------------------------------------
;; Entry point

(defn render
  "Renders the template `name` of `env` with `context` (a `java.util.Map`
  from variable names to template values) as its root scope.  Returns the
  output string.  Throws `ex-info` with `:type :sitegen.template/error` and a
  `:kind` of :syntax, :filter, :undefined, :template or :type on failure."
  ^String [env ^String name ^Map context]
  (let [root (new-scope nil)]
    (.putAll ^HashMap (.vars root) context)
    (let [tpl (load-template env name)
          tscope (new-scope root)
          rs (->RState env (make-chains tpl) tscope)
          out (StringBuilder.)]
      (run-template rs tpl out)
      (.toString out))))
