(ns jsonschema.keywords
  "Compilation of individual schema keywords into evaluator closures.

  Every keyword of a schema object is decoded once, at compile time, into a
  function `(fn [instance scope])`. A checker returns `nil` when the instance
  is rejected and otherwise an *annotation pair* `[evaluated-items
  evaluated-properties]`: each element is `nil` (nothing), `:all`, or a set
  of indices / property names. The pair `ok` stands for \"accepted, nothing
  evaluated\". `scope` is the dynamic scope: a vector of base URIs, outermost
  first.

  The compiler context `ctx` is a map with:

  * `:sub`          `(fn [schema base])` -> compiled subschema (a function with
                    the same signature as a checker), or nil if `schema` is
                    not a schema;
  * `:resolve-ref`  `(fn [base ref])` -> compiled target schema (throws when
                    it cannot be found);
  * `:resolve-dynamic-ref` `(fn [base ref])` -> `(fn [scope])` -> target;
  * `:pattern`      `(fn [pattern-string])` -> delay of a compiled regex;
  * `:tracking?`    whether annotations must be collected at all."
  (:require [jsonschema.regex :as regex]
            [jsonschema.value :as value]
            [jsonschema.registry :as registry])
  (:import (java.math BigDecimal)))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Annotations

(def ok
  "Result of a keyword that accepts without evaluating anything."
  [nil nil])

(defn- union-set [a b]
  (cond (nil? a) b
        (nil? b) a
        (identical? a :all) a
        (identical? b :all) b
        :else (if (< (count a) (count b)) (into b a) (into a b))))

(defn merge-annotations
  "Union of two annotation pairs."
  [a b]
  (cond (identical? a ok) b
        (identical? b ok) a
        :else [(union-set (nth a 0) (nth b 0)) (union-set (nth a 1) (nth b 1))]))

;; ---------------------------------------------------------------------------
;; Helpers

(defn- number-val ^BigDecimal [v] (when (number? v) (value/->decimal v)))

(defn- non-neg-int-val
  "A size-limit keyword value as a long, or nil if `v` is not a number."
  [v mode]
  (when (number? v) (value/count-bound v mode)))

(defn- type-matcher [names]
  (let [names (set names)
        any-number? (contains? names "number")
        integer? (contains? names "integer")]
    (fn [inst]
      (cond
        (nil? inst) (contains? names "null")
        (instance? Boolean inst) (contains? names "boolean")
        (number? inst) (or any-number? (and integer? (value/integer-value? inst)))
        (string? inst) (contains? names "string")
        (map? inst) (contains? names "object")
        (vector? inst) (contains? names "array")
        :else false))))

;; ---------------------------------------------------------------------------
;; Keyword compilers: (fn [ctx m v base]) -> checker or nil
;;   m is the whole schema object, v the keyword's value, base its base URI.

(defn- c-type [_ _ v _]
  (when (or (string? v) (and (vector? v) (every? string? v)))
    (let [match? (type-matcher (if (string? v) [v] v))]
      (fn [inst _] (when (match? inst) ok)))))

(defn- bucket [vals]
  (group-by value/json-hash vals))

(defn- c-enum [_ _ v _]
  (when (vector? v)
    (let [b (bucket v)]
      (fn [inst _]
        (when (some #(value/json-equal? inst %) (get b (value/json-hash inst))) ok)))))

(defn- c-const [_ _ v _]
  (fn [inst _]
    (when (value/json-equal? inst v) ok)))

(defn- numeric-check [pred]
  (fn [_ _ v _]
    (when (number? v)
      (let [lim (value/->decimal v)]
        (fn [inst _]
          (if (number? inst)
            (when (pred (.compareTo (value/->decimal inst) lim)) ok)
            ok))))))

(def ^:private c-maximum (numeric-check #(<= (long %) 0)))
(def ^:private c-minimum (numeric-check #(>= (long %) 0)))
(def ^:private c-exclusive-maximum (numeric-check #(< (long %) 0)))
(def ^:private c-exclusive-minimum (numeric-check #(> (long %) 0)))

(defn- c-multiple-of [_ _ v _]
  (when (and (number? v) (pos? (.signum (value/->decimal v))))
    (fn [inst _]
      (if (number? inst)
        (when (value/multiple-of? inst v) ok)
        ok))))

(defn- length-check [measure upper? pred-type]
  (fn [_ _ v _]
    (when-let [lim (non-neg-int-val v (if upper? :floor :ceiling))]
      (let [lim (long lim)]
        (fn [inst _]
          (if (pred-type inst)
            (let [n (long (measure inst))]
              (when (if upper? (<= n lim) (>= n lim)) ok))
            ok))))))

(defn- str-len [s] (value/code-point-length s))
(defn- coll-count [c] (count c))

(def ^:private c-max-length (length-check str-len true string?))
(def ^:private c-min-length (length-check str-len false string?))
(def ^:private c-max-items (length-check coll-count true vector?))
(def ^:private c-min-items (length-check coll-count false vector?))
(def ^:private c-max-properties (length-check coll-count true map?))
(def ^:private c-min-properties (length-check coll-count false map?))

(defn- c-pattern [ctx _ v _]
  (when (string? v)
    (let [re ((:pattern ctx) v)]
      (fn [inst _]
        (if (string? inst)
          (when (regex/search? @re inst) ok)
          ok)))))

(defn- c-unique-items [_ _ v _]
  (when (true? v)
    (fn [inst _]
      (if (vector? inst)
        (when (value/all-unique? inst) ok)
        ok))))

(defn- c-prefix-items [ctx _ v base]
  (when (vector? v)
    (let [nodes (mapv #((:sub ctx) % base) v)
          nn (count nodes)
          tracking? (:tracking? ctx)]
      (fn [inst scope]
        (if (vector? inst)
          (let [len (count inst)
                k (min nn len)]
            (loop [i 0]
              (if (< i k)
                (let [node (nth nodes i)]
                  (when (or (nil? node) (node (nth inst i) scope))
                    (recur (inc i))))
                (cond (not tracking?) ok
                      (== k len) [:all nil]
                      :else [(set (range k)) nil]))))
          ok)))))

(defn- c-items [ctx m v base]
  (when-let [node ((:sub ctx) v base)]
    (let [pi (get m "prefixItems")
          start (if (vector? pi) (count pi) 0)
          tracking? (:tracking? ctx)]
      (fn [inst scope]
        (if (vector? inst)
          (let [len (count inst)]
            (loop [i start]
              (if (< i len)
                (when (node (nth inst i) scope) (recur (inc i)))
                (if (and tracking? (> len 0)) [:all nil] ok))))
          ok)))))

(defn- c-contains [ctx m v base]
  (when-let [node ((:sub ctx) v base)]
    (let [mn (or (non-neg-int-val (get m "minContains") :ceiling) 1)
          mx (non-neg-int-val (get m "maxContains") :floor)
          tracking? (:tracking? ctx)]
      (fn [inst scope]
        (if (vector? inst)
          (let [len (count inst)
                hits (loop [i 0, acc (transient [])]
                       (if (< i len)
                         (recur (inc i) (if (node (nth inst i) scope) (conj! acc i) acc))
                         (persistent! acc)))
                h (count hits)]
            (when (and (>= h mn) (or (nil? mx) (<= h (long mx))))
              (if tracking? [(set hits) nil] ok)))
          ok)))))

(defn- c-required [_ _ v _]
  (when (and (vector? v) (every? string? v))
    (fn [inst _]
      (if (map? inst)
        (when (every? #(contains? inst %) v) ok)
        ok))))

(defn- c-dependent-required [_ _ v _]
  (when (map? v)
    (let [deps (vec (filter (fn [[_ r]] (and (vector? r) (every? string? r))) v))]
      (fn [inst _]
        (if (map? inst)
          (when (every? (fn [[k reqs]]
                          (or (not (contains? inst k))
                              (every? #(contains? inst %) reqs)))
                        deps)
            ok)
          ok)))))

(defn- sub-map
  "Compiles a map of subschemas; entries that are not schemas are dropped."
  [ctx v base]
  (persistent!
   (reduce-kv (fn [acc k s]
                (if-let [node ((:sub ctx) s base)] (assoc! acc k node) acc))
              (transient {}) v)))

(defn- c-properties [ctx _ v base]
  (when (map? v)
    (let [pm (sub-map ctx v base)
          tracking? (:tracking? ctx)]
      (fn [inst scope]
        (if (map? inst)
          (let [r (reduce-kv
                   (fn [acc k node]
                     (if (contains? inst k)
                       (if (node (get inst k) scope)
                         (if tracking? (conj! acc k) acc)
                         (reduced ::fail))
                       acc))
                   (transient #{}) pm)]
            (cond (identical? r ::fail) nil
                  tracking? [nil (persistent! r)]
                  :else ok))
          ok)))))

(defn- pattern-entries [ctx v base]
  (vec (for [[p s] v
             :let [node ((:sub ctx) s base)]
             :when node]
         [((:pattern ctx) p) node])))

(defn- c-pattern-properties [ctx _ v base]
  (when (map? v)
    (let [entries (pattern-entries ctx v base)
          tracking? (:tracking? ctx)]
      (fn [inst scope]
        (if (map? inst)
          (let [r (reduce-kv
                   (fn [acc k x]
                     (let [matched (reduce (fn [matched [re node]]
                                             (if (regex/search? @re k)
                                               (if (node x scope) true (reduced ::fail))
                                               matched))
                                           false entries)]
                       (cond (identical? matched ::fail) (reduced ::fail)
                             (and matched tracking?) (conj! acc k)
                             :else acc)))
                   (transient #{}) inst)]
            (cond (identical? r ::fail) nil
                  tracking? [nil (persistent! r)]
                  :else ok))
          ok)))))

(defn- c-additional-properties [ctx m v base]
  (when-let [node ((:sub ctx) v base)]
    (let [props (let [p (get m "properties")] (if (map? p) p {}))
          res (let [p (get m "patternProperties")]
                (if (map? p) (mapv (:pattern ctx) (keys p)) []))
          tracking? (:tracking? ctx)]
      (fn [inst scope]
        (if (map? inst)
          (let [good? (reduce-kv
                       (fn [_ k x]
                         (if (or (contains? props k)
                                 (some #(regex/search? @% k) res))
                           true
                           (if (node x scope) true (reduced false))))
                       true inst)]
            (when good? (if tracking? [nil :all] ok)))
          ok)))))

(defn- c-property-names [ctx _ v base]
  (when-let [node ((:sub ctx) v base)]
    (fn [inst scope]
      (if (map? inst)
        (when (every? #(node % scope) (keys inst)) ok)
        ok))))

(defn- c-dependent-schemas [ctx _ v base]
  (when (map? v)
    (let [sm (sub-map ctx v base)]
      (fn [inst scope]
        (if (map? inst)
          (reduce-kv (fn [acc k node]
                       (if (contains? inst k)
                         (if-let [r (node inst scope)]
                           (merge-annotations acc r)
                           (reduced nil))
                         acc))
                     ok sm)
          ok)))))

(defn- sub-vec [ctx v base]
  (when (vector? v) (into [] (keep #((:sub ctx) % base)) v)))

(defn- c-all-of [ctx _ v base]
  (when-let [nodes (sub-vec ctx v base)]
    (fn [inst scope]
      (reduce (fn [acc node]
                (if-let [r (node inst scope)] (merge-annotations acc r) (reduced nil)))
              ok nodes))))

(defn- c-any-of [ctx _ v base]
  (when-let [nodes (sub-vec ctx v base)]
    (let [tracking? (:tracking? ctx)]
      (fn [inst scope]
        (if tracking?
          (let [rs (keep #(% inst scope) nodes)]
            (when (seq rs) (reduce merge-annotations ok rs)))
          (when (some #(% inst scope) nodes) ok))))))

(defn- c-one-of [ctx _ v base]
  (when-let [nodes (sub-vec ctx v base)]
    (fn [inst scope]
      (loop [ns (seq nodes), found nil]
        (if-not ns
          found
          (if-let [r ((first ns) inst scope)]
            (if found nil (recur (next ns) r))
            (recur (next ns) found)))))))

(defn- c-not [ctx _ v base]
  (when-let [node ((:sub ctx) v base)]
    (fn [inst scope] (if (node inst scope) nil ok))))

(defn- c-if [ctx m v base]
  (when-let [if-node ((:sub ctx) v base)]
    (let [then-node ((:sub ctx) (get m "then") base)
          else-node ((:sub ctx) (get m "else") base)]
      (fn [inst scope]
        (if-let [r (if-node inst scope)]
          (if then-node
            (when-let [t (then-node inst scope)] (merge-annotations r t))
            r)
          (if else-node (else-node inst scope) ok))))))

(defn- c-ref [ctx _ v base]
  (when (string? v)
    (let [target (delay ((:resolve-ref ctx) base v))]
      (fn [inst scope] (@target inst scope)))))

(defn- c-dynamic-ref [ctx _ v base]
  (when (string? v)
    (let [target (delay ((:resolve-dynamic-ref ctx) base v))]
      (fn [inst scope] ((@target scope) inst scope)))))

;; unevaluatedItems / unevaluatedProperties are applied after everything else:
;; (fn [inst scope annotations]) -> annotations or nil.

(defn- c-unevaluated-items [ctx _ v base]
  (when-let [node ((:sub ctx) v base)]
    (fn [inst scope ann]
      (let [seen (nth ann 0)]
        (if (identical? seen :all)
          ann
          (let [len (count inst)]
            (loop [i 0]
              (if (< i len)
                (if (or (contains? seen i) (node (nth inst i) scope))
                  (recur (inc i))
                  nil)
                (merge-annotations ann [:all nil])))))))))

(defn- c-unevaluated-properties [ctx _ v base]
  (when-let [node ((:sub ctx) v base)]
    (fn [inst scope ann]
      (let [seen (nth ann 1)]
        (if (identical? seen :all)
          ann
          (when (reduce-kv (fn [_ k x]
                             (if (or (contains? seen k) (node x scope)) true (reduced false)))
                           true inst)
            (merge-annotations ann [nil :all])))))))

(def keyword-compilers
  "Map from keyword name to its compiler `(fn [ctx schema value base])`."
  {"type" c-type
   "enum" c-enum
   "const" c-const
   "maximum" c-maximum
   "minimum" c-minimum
   "exclusiveMaximum" c-exclusive-maximum
   "exclusiveMinimum" c-exclusive-minimum
   "multipleOf" c-multiple-of
   "maxLength" c-max-length
   "minLength" c-min-length
   "pattern" c-pattern
   "maxItems" c-max-items
   "minItems" c-min-items
   "uniqueItems" c-unique-items
   "prefixItems" c-prefix-items
   "items" c-items
   "contains" c-contains
   "maxProperties" c-max-properties
   "minProperties" c-min-properties
   "required" c-required
   "dependentRequired" c-dependent-required
   "properties" c-properties
   "patternProperties" c-pattern-properties
   "additionalProperties" c-additional-properties
   "propertyNames" c-property-names
   "dependentSchemas" c-dependent-schemas
   "allOf" c-all-of
   "anyOf" c-any-of
   "oneOf" c-one-of
   "not" c-not
   "if" c-if
   "$ref" c-ref
   "$dynamicRef" c-dynamic-ref})

(defn compile-keywords
  "Compiles every keyword of the schema object `m` (whose own base URI is
  `base`). Returns `{:checks [checker ...], :late-items f-or-nil,
  :late-props f-or-nil}`."
  [ctx m base]
  (let [checks (into [] (keep (fn [[k v]]
                                (when-let [comp (get keyword-compilers k)]
                                  (comp ctx m v base))))
                     m)]
    {:checks checks
     :late-items (when (contains? m "unevaluatedItems")
                   (c-unevaluated-items ctx m (get m "unevaluatedItems") base))
     :late-props (when (contains? m "unevaluatedProperties")
                   (c-unevaluated-properties ctx m (get m "unevaluatedProperties") base))}))
