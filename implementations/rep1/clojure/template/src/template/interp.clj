(ns template.interp
  "The tree-walking interpreter.

  A rendering is described by an *rc* (render context): the shared
  environment (template sources and the cache of loaded templates), the
  block chains of this rendering and its template scope."
  (:require [template.errors :as err]
            [template.filters :as filters]
            [template.ops :as ops]
            [template.parser :as parser]
            [template.scope :as sc :refer [bind! lookup new-scope]]
            [template.values :as v :refer [undefined?]])
  (:import (java.util HashMap LinkedHashMap)
           (template.values Macro Super)))

(set! *warn-on-reflection* true)

(defrecord RC [env ^HashMap chains tscope])

(declare eval-expr exec-nodes render-chain-entry render-template)

;; ---------------------------------------------------------------------------
;; Template loading

(defn load-template
  "Load (lex, parse, filter-check) the template called `name`, at most once."
  [env ^String name]
  (let [^HashMap cache (:cache env)]
    (or (.get cache name)
        (let [src (get (:sources env) name ::missing)]
          (when (identical? src ::missing)
            (err/fail :template (str "template not found: " name)))
          (let [tpl (parser/parse src)]
            (.put cache name tpl)
            tpl)))))

(defn- template-by-value [env name-value]
  (cond
    (string? name-value) (load-template env name-value)
    (undefined? name-value) (err/fail :undefined "undefined template name")
    :else (err/fail :type "template name must be a string")))

;; ---------------------------------------------------------------------------
;; Expressions

(defn- get-item
  "Attribute/subscript access `a[k]`."
  [a k]
  (cond
    (undefined? a) (err/fail :undefined "attribute access on an undefined value")
    (undefined? k) (err/fail :undefined "undefined subscript")
    (v/dict? a) (if (string? k)
                  (.getOrDefault ^LinkedHashMap a ^String k v/undefined)
                  v/undefined)
    (and (vector? a) (v/int-like? k))
    (let [i (long (v/->num k)) n (count a) i (if (neg? i) (+ i n) i)]
      (if (and (>= i 0) (< i n)) (nth a i) v/undefined))
    (and (string? a) (v/int-like? k))
    (let [^String s a
          i (long (v/->num k))
          n (v/code-point-length s)
          i (if (neg? i) (+ i n) i)]
      (if (and (>= i 0) (< i n))
        (let [from (.offsetByCodePoints s 0 (int i))]
          (.substring s from (+ from (Character/charCount (.codePointAt s from)))))
        v/undefined))
    :else v/undefined))

(defn- call-range [args kwargs]
  (when (seq kwargs) (err/fail :type "range takes no keyword arguments"))
  (when (or (zero? (count args)) (> (count args) 3))
    (err/fail :type "range takes one to three arguments"))
  (doseq [a args]
    (cond (undefined? a) (err/fail :undefined "undefined range argument")
          (not (v/int-like? a)) (err/fail :type "range arguments must be integers")))
  (let [ns (mapv #(long (v/->num %)) args)
        [start stop step] (case (count ns)
                            1 [0 (nth ns 0) 1]
                            2 [(nth ns 0) (nth ns 1) 1]
                            3 ns)]
    (when (zero? step) (err/fail :type "range step is zero"))
    (vec (range start stop step))))

(defn- call-macro [^Macro m args kwargs]
  (let [params (:params m)
        scope (new-scope (:scope m))
        np (count params)]
    (when (> (count args) np) (err/fail :type "too many arguments for macro"))
    (dotimes [i (count args)]
      (bind! scope (nth (nth params i) 0) (nth args i)))
    (doseq [[k val] kwargs]
      (when-not (some #(= k (nth % 0)) params) (err/fail :type "unknown keyword argument"))
      (when (sc/bound-here? scope k) (err/fail :type "argument given twice"))
      (bind! scope k val))
    (doseq [[pn default] params]
      (when-not (sc/bound-here? scope pn)
        (bind! scope pn (if default (eval-expr default scope (:rc m)) v/undefined))))
    (let [sb (StringBuilder.)]
      (exec-nodes (:body m) scope (:rc m) sb)
      (.toString sb))))

(defn- call-super [^Super s args kwargs]
  (when (or (seq args) (seq kwargs)) (err/fail :type "super takes no arguments"))
  (let [sb (StringBuilder.)]
    (render-chain-entry (:rc s) (:name s) (inc (:index s)) sb true)
    (.toString sb)))

(defn- eval-call [e scope rc]
  (let [callee (eval-expr (nth e 1) scope rc)
        args (mapv #(eval-expr % scope rc) (nth e 2))
        kwargs (mapv (fn [[k x]] [k (eval-expr x scope rc)]) (nth e 3))]
    (cond
      (undefined? callee) (err/fail :undefined "call of an undefined value")
      (instance? Macro callee) (call-macro callee args kwargs)
      (identical? callee v/range-builtin) (call-range args kwargs)
      (instance? Super callee) (call-super callee args kwargs)
      :else (err/fail :type "value is not callable"))))

(defn- eval-compare [e scope rc]
  (loop [left (eval-expr (nth e 1) scope rc)
         chain (nth e 2)
         i 0]
    (let [[op rhs-expr] (nth chain i)
          rhs (eval-expr rhs-expr scope rc)]
      (if (ops/compare-chain-op op left rhs)
        (if (< (inc i) (count chain)) (recur rhs chain (inc i)) true)
        false))))

(defn eval-expr
  "Evaluate expression node `e` in `scope`."
  [e scope rc]
  (case (nth e 0)
    :lit (nth e 1)
    :name (lookup scope (nth e 1))
    :get (let [a (eval-expr (nth e 1) scope rc)
               k (eval-expr (nth e 2) scope rc)]
           (get-item a k))
    :binop (let [a (eval-expr (nth e 2) scope rc)
                 b (eval-expr (nth e 3) scope rc)]
             (ops/binary (nth e 1) a b))
    :filter (let [x (eval-expr (nth e 1) scope rc)
                  args (mapv #(eval-expr % scope rc) (nth e 3))]
              (filters/apply-filter (nth e 2) x args))
    :call (eval-call e scope rc)
    :compare (eval-compare e scope rc)
    :and (let [a (eval-expr (nth e 1) scope rc)]
           (if (v/truthy? a) (eval-expr (nth e 2) scope rc) a))
    :or (let [a (eval-expr (nth e 1) scope rc)]
          (if (v/truthy? a) a (eval-expr (nth e 2) scope rc)))
    :not (not (v/truthy? (eval-expr (nth e 1) scope rc)))
    :neg (ops/neg (eval-expr (nth e 1) scope rc))
    :defined (let [x (eval-expr (nth e 1) scope rc)]
               (if (nth e 2) (undefined? x) (not (undefined? x))))
    :list (mapv #(eval-expr % scope rc) (nth e 1))))

;; ---------------------------------------------------------------------------
;; Statements

(defn- add-blocks! [^HashMap chains tpl]
  (doseq [[name body] (:blocks tpl)]
    (let [chain (.get chains name)]
      (.put chains name (if chain (conj chain body) [body])))))

(defn- render-chain-entry
  "Render entry `k` of the block chain `name` into `sb`. A missing entry is a
  no-op, or an `undefined` error when it was requested by `super()`."
  [^RC rc name k sb super?]
  (let [chain (.get ^HashMap (:chains rc) name)]
    (if (and chain (< (long k) (count chain)))
      (let [scope (new-scope (:tscope rc))]
        (bind! scope "super" (Super. rc name k))
        (exec-nodes (nth chain k) scope rc sb))
      (when super? (err/fail :undefined "super() without a less derived block")))))

(defn- exec-for [node scope rc ^StringBuilder sb]
  (let [xs (v/sequence-view (eval-expr (nth node 2) scope rc))
        n (count xs)
        var-name (nth node 1)
        body (nth node 3)]
    (if (zero? n)
      (when-let [eb (nth node 4)] (exec-nodes eb scope rc sb))
      (dotimes [i n]
        (let [s (new-scope scope)
              loop-dict (LinkedHashMap.)]
          (.put loop-dict "index" (inc i))
          (.put loop-dict "index0" (long i))
          (.put loop-dict "first" (zero? i))
          (.put loop-dict "last" (== i (dec n)))
          (.put loop-dict "length" (long n))
          (bind! s var-name (nth xs i))
          (bind! s "loop" loop-dict)
          (exec-nodes body s rc sb))))))

(defn- render-include [node scope rc sb]
  (let [env (:env rc)
        tpl (template-by-value env (eval-expr (nth node 1) scope rc))]
    (render-template env tpl (new-scope scope) sb)))

(defn- exec-node [node scope ^RC rc ^StringBuilder sb]
  (case (nth node 0)
    :text (.append sb ^String (nth node 1))
    :print (v/write-str! sb (eval-expr (nth node 1) scope rc))
    :if (loop [branches (nth node 1) i 0]
          (if (< i (count branches))
            (let [[c body] (nth branches i)]
              (if (v/truthy? (eval-expr c scope rc))
                (exec-nodes body scope rc sb)
                (recur branches (inc i))))
            (when-let [eb (nth node 2)] (exec-nodes eb scope rc sb))))
    :for (exec-for node scope rc sb)
    :set (bind! scope (nth node 1) (eval-expr (nth node 2) scope rc))
    :macro (bind! scope (nth node 1) (Macro. (nth node 1) (nth node 2) (nth node 3) scope rc))
    :include (render-include node scope rc sb)
    :block (render-chain-entry rc (nth node 1) 0 sb false)))

(defn- exec-nodes [nodes scope rc sb]
  (let [n (count nodes)]
    (loop [i 0]
      (when (< i n)
        (exec-node (nth nodes i) scope rc sb)
        (recur (inc i))))))

;; ---------------------------------------------------------------------------
;; Rendering a template (with inheritance)

(defn- run-template
  "Execute `tpl`, then each parent introduced by `extends`, in `rc`'s template
  scope, appending to `sb`."
  [^RC rc tpl sb]
  (let [scope (:tscope rc)]
    (loop [tpl tpl]
      (let [body (:body tpl)
            n (count body)
            parent (loop [i 0 parent nil]
                     (if (< i n)
                       (let [node (nth body i)]
                         (cond
                           (identical? (nth node 0) :extends)
                           (let [ptpl (template-by-value (:env rc) (eval-expr (nth node 1) scope rc))]
                             (add-blocks! (:chains rc) ptpl)
                             (recur (inc i) ptpl))

                           (nil? parent) (do (exec-node node scope rc sb) (recur (inc i) parent))

                           ;; after `extends`: only set and macro have an effect
                           (or (identical? (nth node 0) :set) (identical? (nth node 0) :macro))
                           (do (exec-node node scope rc sb) (recur (inc i) parent))

                           :else (recur (inc i) parent)))
                       parent))]
        (when parent (recur parent))))))

(defn- render-template
  "Render `tpl` as a fresh rendering with template scope `tscope`."
  [env tpl tscope sb]
  (let [chains (HashMap.)
        rc (RC. env chains tscope)]
    (add-blocks! chains tpl)
    (run-template rc tpl sb)))

(def ^:private builtins
  (doto (HashMap.) (.put "range" v/range-builtin)))

(defn render
  "Render template `main-name` from `sources` (a map of name -> source string)
  with `context`, a `LinkedHashMap` of initial variables. Returns the output
  string or throws a template error."
  ^String [sources ^String main-name ^LinkedHashMap context]
  (let [env {:sources sources :cache (HashMap.)}
        tpl (load-template env main-name)
        root (sc/scope-over context (sc/scope-over builtins nil))
        sb (StringBuilder.)]
    (render-template env tpl (new-scope root) sb)
    (.toString sb)))
