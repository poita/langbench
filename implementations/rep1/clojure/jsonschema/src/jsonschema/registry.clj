(ns jsonschema.registry
  "The schema index: one walk over each schema document that records, for
  every schema object, the base URI it inherits, and fills the lookup tables
  for schema resources (`$id`), anchors (`$anchor`) and dynamic anchors
  (`$dynamicAnchor`). See sections 6.1-6.3 of the specification.

  The tables are mutable `java.util` maps that are only written while the
  registry is being built."
  (:require [jsonschema.uri :as uri])
  (:import (java.util HashMap IdentityHashMap)))

(set! *warn-on-reflection* true)

(def schema-keywords
  "Keywords whose value is a single subschema (and are indexed)."
  ["additionalProperties" "propertyNames" "items" "contains" "not" "if" "then" "else"
   "unevaluatedItems" "unevaluatedProperties" "contentSchema"])

(def array-keywords
  "Keywords whose value is an array of subschemas."
  ["allOf" "anyOf" "oneOf" "prefixItems"])

(def map-keywords
  "Keywords whose value is a map of subschemas."
  ["$defs" "properties" "patternProperties" "dependentSchemas"])

(defn schema?
  "True when `v` can be a schema: a boolean or an object."
  [v]
  (or (map? v) (instance? Boolean v)))

(defn subschemas
  "The subschemas of the schema object `m`, per section 6.2."
  [m]
  (concat
   (for [k schema-keywords :let [v (get m k)] :when (schema? v)] v)
   (for [k array-keywords :let [v (get m k)] :when (vector? v) c v :when (schema? c)] c)
   (for [k map-keywords :let [v (get m k)] :when (map? v) c (vals v) :when (schema? c)] c)))

(defn anchor-key
  "The key under which the anchor `name` of the resource `base` is stored."
  [base name]
  (str base "#" name))

(defrecord Registry
           [resources     ; base URI -> schema (the root of the resource)
            anchors       ; "base#name" -> schema, for $anchor
            dyn-anchors   ; "base#name" -> schema, for $dynamicAnchor
            inbase        ; schema object (by identity) -> base URI inherited from its parent
            tracking?])   ; volatile: does any schema use unevaluated*?

(defn- put-absent! [^HashMap m k v]
  (when-not (.containsKey m k) (.put m k v)))

(defn- index-document!
  [^Registry reg retrieval-uri root]
  (let [^HashMap resources (:resources reg)
        ^HashMap anchors (:anchors reg)
        ^HashMap dyn (:dyn-anchors reg)
        ^IdentityHashMap inbase (:inbase reg)]
    (letfn [(walk [m parent-base]
              (when (map? m)
                (.put inbase m parent-base)
                (let [id (get m "$id")
                      base (if (string? id)
                             (uri/resolve-reference parent-base (uri/strip-fragment id))
                             parent-base)]
                  (when (string? id) (put-absent! resources base m))
                  (let [a (get m "$anchor")
                        d (get m "$dynamicAnchor")]
                    (when (string? a) (put-absent! anchors (anchor-key base a) m))
                    (when (string? d) (put-absent! dyn (anchor-key base d) m)))
                  (when (or (contains? m "unevaluatedItems") (contains? m "unevaluatedProperties"))
                    (vreset! (:tracking? reg) true))
                  (doseq [c (subschemas m)] (walk c base)))))]
      (walk root retrieval-uri)
      (put-absent! resources retrieval-uri root))))

(defn build
  "Builds a registry from `docs`, a sequence of `[retrieval-uri schema]`
  pairs. Earlier documents win when two claim the same URI."
  [docs]
  (let [reg (->Registry (HashMap.) (HashMap.) (HashMap.) (IdentityHashMap.) (volatile! false))]
    (doseq [[retrieval-uri root] docs]
      (index-document! reg retrieval-uri root))
    reg))

(defn resource
  "The schema registered under the document URI `doc`, or nil."
  [^Registry reg doc]
  (.get ^HashMap (:resources reg) doc))

(defn anchor
  "The schema registered under `(base, name)` for a plain-name lookup (an
  `$anchor` wins over a `$dynamicAnchor` of the same name), or nil."
  [^Registry reg base name]
  (let [k (anchor-key base name)]
    (or (.get ^HashMap (:anchors reg) k)
        (.get ^HashMap (:dyn-anchors reg) k))))

(defn dynamic-anchor
  "The schema marked as a dynamic anchor `(base, name)`, or nil."
  [^Registry reg base name]
  (.get ^HashMap (:dyn-anchors reg) (anchor-key base name)))

(defn inherited-base
  "The base URI that the schema object `m` inherits from its parent, or
  `default` when `m` was not seen by the indexing walk."
  [^Registry reg m default]
  (let [^IdentityHashMap t (:inbase reg)]
    (if (.containsKey t m) (.get t m) default)))

(defn tracking?
  "True when some indexed schema uses `unevaluatedItems` or
  `unevaluatedProperties`, so evaluation has to collect annotations."
  [^Registry reg]
  @(:tracking? reg))
