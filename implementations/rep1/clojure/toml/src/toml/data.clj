(ns toml.data
  "The data model shared by the reader, the writer and the JSON codec.

  A *tagged tree* is built from three kinds of node:

  * a table is a Clojure map from string keys to nodes;
  * an array is a vector of nodes;
  * a scalar is a [[Scalar]] record: a `:type` keyword plus the canonical
    `:value` text of the scalar.

  Scalars are kept as text, so no information is lost between reading and
  writing (see `toml.number` and `toml.datetime` for the text forms).")

(def scalar-types
  "The eight scalar types."
  #{:string :integer :float :bool :datetime :datetime-local :date-local :time-local})

(defrecord Scalar [type value])

(defn scalar
  "Creates a scalar of `type` (one of [[scalar-types]]) with canonical text `value`."
  [type value]
  (->Scalar type value))

(defn scalar? [x] (instance? Scalar x))

(defn table?
  "True for a table node: a map that is not a scalar."
  [x]
  (and (map? x) (not (instance? Scalar x))))

(defn array? [x] (vector? x))
