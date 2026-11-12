(ns jsonschema.schema
  "Compiles schema documents into evaluator functions.

  [[compile-documents]] indexes the documents ([[jsonschema.registry]]) and
  returns a compiler context. Schema objects are compiled on demand (the
  root, and each reference target the first time it is used) and cached by
  identity, so keyword decoding, URI resolution and pattern compilation each
  happen once."
  (:require [jsonschema.keywords :as kw]
            [jsonschema.regex :as regex]
            [jsonschema.registry :as registry]
            [jsonschema.uri :as uri])
  (:import (java.util HashMap IdentityHashMap)))

(set! *warn-on-reflection* true)

(defn- accept-all [_ _] kw/ok)
(defn- reject-all [_ _] nil)

(declare compile-schema)

(defn- build-node
  "Compiles the schema object `m`, which inherits `parent-base`."
  [ctx m parent-base]
  (let [id (get m "$id")
        base (if (string? id)
               (uri/resolve-reference parent-base (uri/strip-fragment id))
               parent-base)
        {:keys [checks late-items late-props]} (kw/compile-keywords ctx m base)
        checks (object-array checks)
        n (alength checks)]
    (fn [inst scope]
      (let [scope (if (= base (peek scope)) scope (conj scope base))]
        (loop [i 0, ann kw/ok]
          (if (< i n)
            (when-let [r ((aget checks i) inst scope)]
              (recur (inc i) (kw/merge-annotations ann r)))
            (cond
              (and late-items (vector? inst)) (late-items inst scope ann)
              (and late-props (map? inst)) (late-props inst scope ann)
              :else ann)))))))

(defn compile-schema
  "Returns the evaluator function for `schema` (a boolean or an object)
  inheriting `parent-base`, or nil when `schema` is not a schema. Results for
  objects are cached in the context."
  [ctx schema parent-base]
  (cond
    (true? schema) accept-all
    (false? schema) reject-all
    (map? schema)
    (if (empty? schema)
      accept-all
      (let [^IdentityHashMap cache (:nodes ctx)]
        (or (.get cache schema)
            (let [node (build-node ctx schema parent-base)]
              (.put cache schema node)
              node))))
    :else nil))

(defn- node-for-raw
  "The evaluator for the schema `raw` found in the registry; `default-base`
  is used when the indexing walk never saw it."
  [ctx raw default-base]
  (compile-schema ctx raw (registry/inherited-base (:registry ctx) raw default-base)))

(defn- fail-ref [ref uri why]
  (throw (ex-info (str "Cannot resolve reference " (pr-str ref) " (" uri "): " why)
                  {:type ::unresolved-reference :ref ref :uri uri})))

(defn- lookup
  "Finds the schema that `uri` (an absolute reference, resolved from `ref`)
  points to and returns its evaluator."
  [ctx ref uri]
  (let [reg (:registry ctx)
        [doc frag] (uri/split-fragment uri)
        frag (when frag (uri/percent-decode frag))]
    (if (or (nil? frag) (= "" frag) (.startsWith ^String frag "/"))
      (let [root (registry/resource reg doc)]
        (when (nil? root) (fail-ref ref uri "no such schema resource"))
        (if (or (nil? frag) (= "" frag))
          (node-for-raw ctx root doc)
          (if-let [[_ target] (uri/pointer-get root frag)]
            (node-for-raw ctx target doc)
            (fail-ref ref uri "JSON Pointer does not resolve"))))
      (if-let [target (registry/anchor reg doc frag)]
        (node-for-raw ctx target doc)
        (fail-ref ref uri "no such anchor")))))

(defn- resolve-ref [ctx base ref]
  (lookup ctx ref (uri/resolve-reference base ref)))

(defn- resolve-dynamic-ref [ctx base ref]
  (let [reg (:registry ctx)
        uri (uri/resolve-reference base ref)
        [doc frag] (uri/split-fragment uri)
        frag (when frag (uri/percent-decode frag))]
    (if (and (seq frag)
             (not (.startsWith ^String frag "/"))
             (registry/dynamic-anchor reg doc frag))
      (fn [scope]
        (let [b (first (filter #(registry/dynamic-anchor reg % frag) scope))
              target (registry/dynamic-anchor reg b frag)]
          (node-for-raw ctx target b)))
      (let [static (lookup ctx ref uri)]
        (fn [_] static)))))

(defn compile-documents
  "Indexes `docs`, a sequence of `[retrieval-uri schema]` pairs, and returns
  a compiler context."
  [docs]
  (let [reg (registry/build docs)
        patterns (HashMap.)
        self (volatile! nil)
        ctx {:registry reg
             :nodes (IdentityHashMap.)
             :tracking? (registry/tracking? reg)
             :pattern (fn [p]
                        (or (.get patterns p)
                            (let [d (delay (regex/compile-pattern p))]
                              (.put patterns p d)
                              d)))
             :sub (fn [schema base] (compile-schema @self schema base))
             :resolve-ref (fn [base ref] (resolve-ref @self base ref))
             :resolve-dynamic-ref (fn [base ref] (resolve-dynamic-ref @self base ref))}]
    (vreset! self ctx)
    ctx))
