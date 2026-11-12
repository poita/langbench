(ns jq.eval
  "Compiles a syntax tree (see [[jq.parser]]) into a *closure* and runs it.

  A closure is a function `(fn [env input emit])`. `env` is a persistent map
  from variable name to value; the closure calls `(emit output)` for each
  output, in the order fixed by the specification, and throws a jq error (see
  [[jq.error]]) when evaluation fails. Streams are therefore push-based: an
  output is handed downstream as soon as it is produced, which gives the lazy,
  ordered semantics (and the partial output before an error) for free."
  (:require [jq.access :as access]
            [jq.builtins :as builtins]
            [jq.error :as err]
            [jq.ops :as ops]
            [jq.value :as v])
  (:import (clojure.lang ExceptionInfo)
           (java.util LinkedHashMap)))

(set! *warn-on-reflection* true)

(declare compile-node)

(defn- literal? [node] (= :lit (node 0)))

(defn- compile-binop [op a b scope]
  (let [f (ops/binary-op op)
        ca (compile-node a scope)]
    (if (literal? b)
      (let [bv (b 1)]
        (fn [env in emit] (ca env in (fn [av] (emit (f av bv))))))
      (let [cb (compile-node b scope)]
        ;; the right operand is the outer loop
        (fn [env in emit]
          (cb env in (fn [bv] (ca env in (fn [av] (emit (f av bv)))))))))))

(defn- compile-index [target key opt? scope]
  (let [ct (compile-node target scope)
        apply-index (if opt?
                      (fn [t k emit]
                        (let [r (access/index-checked t k)]
                          (when-not (identical? r access/fail) (emit r))))
                      (fn [t k emit] (emit (access/index t k))))]
    (if (literal? key)
      (let [k (key 1)]
        (fn [env in emit] (ct env in (fn [t] (apply-index t k emit)))))
      (let [ck (compile-node key scope)]
        (fn [env in emit]
          (ck env in (fn [k] (ct env in (fn [t] (apply-index t k emit))))))))))

(defn- compile-slice [target from to opt? scope]
  (let [ct (compile-node target scope)
        cf (if from (compile-node from scope) (fn [_ _ emit] (emit nil)))
        cto (if to (compile-node to scope) (fn [_ _ emit] (emit nil)))
        apply-slice (if opt?
                      (fn [t a b emit]
                        (let [r (access/slice-checked t a b)]
                          (when-not (identical? r access/fail) (emit r))))
                      (fn [t a b emit] (emit (access/slice t a b))))]
    (fn [env in emit]
      (cf env in
          (fn [a] (cto env in
                       (fn [b] (ct env in (fn [t] (apply-slice t a b emit))))))))))

(defn- compile-iterate [target opt? scope]
  (let [ct (compile-node target scope)]
    (fn [env in emit]
      (ct env in
          (fn [t]
            (let [r (if opt? (access/iterable-checked t) (access/iterable t))]
              (when-not (identical? r access/fail)
                (doseq [x r] (emit x)))))))))

(defn- compile-try [body scope]
  (let [cb (compile-node body scope)]
    (fn [env in emit]
      (let [token (Object.)]
        (try
          (cb env in
              (fn [x]
                (try (emit x)
                     (catch ExceptionInfo e
                       ;; an error raised downstream must not be swallowed here
                       (if (err/jq-error? e)
                         (throw (err/passthrough token e))
                         (throw e))))))
          (catch ExceptionInfo e
            (cond (err/passthrough-of? e token) (throw (err/unwrap-passthrough e))
                  (err/jq-error? e) nil
                  :else (throw e))))))))

(defn- compile-object [entries scope]
  (let [cs (mapv (fn [[k x]] [(compile-node k scope) (compile-node x scope)]) entries)
        n (count cs)]
    (fn [env in emit]
      (letfn [(build [acc]
                (let [m (LinkedHashMap.)]
                  (loop [i 0]
                    (when (< i (count acc))
                      (.put m (nth acc i) (nth acc (inc i)))
                      (recur (+ i 2))))
                  (v/new-obj m)))
              (go [i acc]
                (if (== i n)
                  (emit (build acc))
                  (let [[ck cv] (nth cs i)]
                    (ck env in
                        (fn [k]
                          (when-not (string? k)
                            (err/raise (str "Object keys must be strings")))
                          (cv env in (fn [x] (go (inc i) (conj (conj acc k) x)))))))))]
        (go 0 [])))))

(defn- compile-reduce [src name init update scope]
  (let [csrc (compile-node src scope)
        cinit (compile-node init scope)
        cupd (compile-node update (conj scope name))]
    (fn [env in emit]
      (cinit env in
             (fn [init-v]
               (let [acc (volatile! init-v)]
                 (csrc env in
                       (fn [x]
                         (let [env' (assoc env name x)
                               last-out (volatile! nil)]
                           (cupd env' @acc (fn [o] (vreset! last-out o)))
                           (vreset! acc @last-out))))
                 (emit @acc)))))))

(defn- compile-call [name args scope]
  (let [builder (builtins/lookup name (count args))]
    (when-not builder
      (throw (ex-info (str "jq: " name "/" (count args) " is not defined")
                      {:type ::undefined-function :name name :arity (count args)})))
    (builder (mapv #(compile-node % scope) args))))

(defn compile-node
  "Compiles the syntax tree `node` into a closure. `scope` is the set of
  variable names in scope; referring to another variable throws."
  [node scope]
  (case (node 0)
    :identity (fn [_ in emit] (emit in))
    :lit (let [x (node 1)] (fn [_ _ emit] (emit x)))
    :var (let [name (node 1)]
           (when-not (contains? scope name)
             (throw (ex-info (str "jq: $" name " is not defined")
                             {:type ::undefined-variable :name name})))
           (fn [env _ emit] (emit (get env name))))
    :neg (let [c (compile-node (node 1) scope)]
           (fn [env in emit] (c env in (fn [x] (emit (ops/negate x))))))
    :binop (compile-binop (node 1) (node 2) (node 3) scope)
    :and (let [ca (compile-node (node 1) scope) cb (compile-node (node 2) scope)]
           (fn [env in emit]
             (ca env in (fn [a]
                          (if (v/truthy? a)
                            (cb env in (fn [b] (emit (v/truthy? b))))
                            (emit false))))))
    :or (let [ca (compile-node (node 1) scope) cb (compile-node (node 2) scope)]
          (fn [env in emit]
            (ca env in (fn [a]
                         (if (v/truthy? a)
                           (emit true)
                           (cb env in (fn [b] (emit (v/truthy? b)))))))))
    :comma (let [ca (compile-node (node 1) scope) cb (compile-node (node 2) scope)]
             (fn [env in emit] (ca env in emit) (cb env in emit)))
    :pipe (let [ca (compile-node (node 1) scope) cb (compile-node (node 2) scope)]
            (fn [env in emit] (ca env in (fn [x] (cb env x emit)))))
    :array (if-let [body (node 1)]
             (let [c (compile-node body scope)]
               (fn [env in emit] (emit (builtins/collect c env in))))
             (fn [_ _ emit] (emit [])))
    :object (compile-object (node 1) scope)
    :if (let [cc (compile-node (node 1) scope)
              ct (compile-node (node 2) scope)
              ce (compile-node (node 3) scope)]
          (fn [env in emit]
            (cc env in (fn [c] (if (v/truthy? c) (ct env in emit) (ce env in emit))))))
    :bind (let [csrc (compile-node (node 1) scope)
                name (node 2)
                cbody (compile-node (node 3) (conj scope name))]
            (fn [env in emit]
              (csrc env in (fn [x] (cbody (assoc env name x) in emit)))))
    :reduce (compile-reduce (node 1) (node 2) (node 3) (node 4) scope)
    :index (compile-index (node 1) (node 2) (node 3) scope)
    :slice (compile-slice (node 1) (node 2) (node 3) (node 4) scope)
    :iterate (compile-iterate (node 1) (node 2) scope)
    :try (compile-try (node 1) scope)
    :call (compile-call (node 1) (node 2) scope)))
