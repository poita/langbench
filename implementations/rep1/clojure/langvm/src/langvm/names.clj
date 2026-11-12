(ns langvm.names
  "Resolution of value and struct paths (SPEC 5.4 and 10.2)."
  (:require [langvm.diag :as diag]
            [langvm.program :as program]))

(set! *warn-on-reflection* true)

(defn- module-of [prog mi] (nth (:modules prog) mi))

(defn- value-pub? [prog v]
  (case (first v)
    :fn (:pub (nth (:fns prog) (second v)))
    :variant (:pub (nth (:decls prog) (second v)))))

(defn method-index
  "Index of method `name` in trait `tid`, or nil."
  [prog tid name]
  (let [ms (:methods (nth (:traits-table prog) tid))]
    (first (keep-indexed (fn [i m] (when (= name (:name m)) i)) ms))))

(defn- type-name? [prog mi name]
  (or (contains? program/reserved-names name)
      (contains? #{"Option" "Result"} name)
      (contains? (:types (module-of prog mi)) name)))

(defn resolve-value
  "Resolve the path node `p` (`{:mod :name :pos :name-pos :mod-pos}`) in the
  values namespace of module `mi`.  `locals` is the map of local bindings, or
  nil in a pattern.  Returns one of

    [:local binding]  [:fn id]  [:builtin entry]  [:variant decl vidx]
    [:method trait-id method-index]  [:type]

  or signals the appropriate diagnostic."
  [prog mi p locals]
  (let [{:keys [mod name name-pos mod-pos]} p
        m (module-of prog mi)
        value (fn [v] (case (first v) :fn [:fn (second v)] :variant v))]
    (if mod
      (if-let [im (get (:imports m) mod)]
        (let [v (get (:values (module-of prog im)) name)]
          (when-not v (diag/fail :unknown-name name-pos))
          (when (and (not= im mi) (not (value-pub? prog v)))
            (diag/fail :not-public name-pos))
          (value v))
        (if-let [tid (program/find-visible-trait prog mi mod)]
          (if-let [mx (method-index prog tid name)]
            [:method tid mx]
            (diag/fail :unknown-name name-pos))
          (diag/fail :unknown-module mod-pos)))
      (cond
        (and locals (contains? locals name)) [:local (get locals name)]
        (contains? (:values m) name) (value (get (:values m) name))
        (contains? (:builtins prog) name) [:builtin (get (:builtins prog) name)]
        (contains? (program/prelude-values) name) (get (program/prelude-values) name)
        (type-name? prog mi name) [:type]
        :else (diag/fail :unknown-name name-pos)))))

(defn bare-variant
  "The `[:variant decl vidx]` that the bare identifier `name` denotes in a
  pattern (module items first, then the prelude), or nil."
  [prog mi name]
  (let [v (or (get (:values (module-of prog mi)) name)
              (when-not (contains? (:builtins prog) name)
                (get (program/prelude-values) name)))]
    (when (= :variant (first v)) v)))

(defn resolve-struct-type
  "Resolve the type path `p` of a struct literal or pattern to a decl id.
  Signals unknown-type / not-public / not-struct."
  [prog mi p]
  (let [{:keys [mod name name-pos mod-pos pos]} p
        m (module-of prog mi)
        id (if mod
             (let [im (get (:imports m) mod)]
               (when-not im (diag/fail :unknown-module mod-pos))
               (let [id (get (:types (module-of prog im)) name)]
                 (when-not id (diag/fail :unknown-type name-pos))
                 (when (and (not= im mi) (not (:pub (nth (:decls prog) id))))
                   (diag/fail :not-public name-pos))
                 id))
             (or (get (:types m) name)
                 (get {"Option" program/decl-option "Result" program/decl-result} name)
                 (if (contains? program/reserved-names name)
                   (diag/fail :not-struct pos)
                   (diag/fail :unknown-type name-pos))))]
    (when-not (= :struct (:kind (nth (:decls prog) id)))
      (diag/fail :not-struct pos))
    id))
