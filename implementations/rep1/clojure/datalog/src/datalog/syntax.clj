(ns datalog.syntax
  "The data model shared by every module, plus small helpers over it.

  A *program* is a map `{:rules [rule ...] :queries [atom ...]}`.

  * A *term* is a constant or a variable:
      - integer constant     -> a `Long`          (`5`, `-2`)
      - identifier constant  -> a `Keyword`       (`:alice`)
      - variable             -> a `Symbol`        (`'X`, `'Parent`)
      - anonymous variable   -> the symbol `'_`   (each occurrence is a
        distinct fresh variable)
  * An *atom* is `{:pred \"edge\" :args [term ...]}`.
  * A *literal* is one of
      - `{:op :pos :atom atom}`
      - `{:op :neg :atom atom}`
      - `{:op :cmp :cmp :< :left term :right term}` where `:cmp` is one of
        `:< :<= :> :>= := :!=`.
  * A *rule* is `{:head atom :body [literal ...]}`; a *fact* is a rule with
    an empty body.

  A predicate is identified by its name together with its arity; such a
  *predicate key* is the vector `[name arity]`."
  (:require [clojure.string :as str]))

(defn variable?
  "True for variables, including the anonymous variable `_`."
  [t]
  (symbol? t))

(defn anonymous?
  "True for the anonymous variable `_`."
  [t]
  (= t '_))

(defn constant?
  "True for integer and identifier constants."
  [t]
  (or (integer? t) (keyword? t)))

(defn atom-key
  "The predicate key `[name arity]` of an atom."
  [a]
  [(:pred a) (count (:args a))])

(defn literal-atom
  "The atom of a `:pos` or `:neg` literal, or nil for a comparison."
  [lit]
  (:atom lit))

(defn fact?
  "True when the rule has an empty body."
  [rule]
  (empty? (:body rule)))

(defn constant-str
  "Canonical text of a constant: decimal for integers, the bare name for
  identifiers."
  [c]
  (if (keyword? c) (name c) (str c)))

(defn format-atom
  "Formats a predicate name and a seq of constants as `p(v1, v2, ...)`."
  [pred args]
  (str pred "(" (str/join ", " (map constant-str args)) ")"))

(defn compare-constants
  "The total order on constants: every integer precedes every identifier,
  integers compare numerically, identifiers compare by ASCII byte value."
  [a b]
  (let [ka (keyword? a) kb (keyword? b)]
    (cond (and ka kb) (compare (name a) (name b))
          ka 1
          kb -1
          :else (compare a b))))
