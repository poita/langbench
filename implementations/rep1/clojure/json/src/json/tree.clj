(ns json.tree
  "The parsed representation of a JSON document.

  A document is parsed into a *tree* of plain Clojure values:

  | JSON      | tree value                                            |
  |-----------|-------------------------------------------------------|
  | `null`    | `nil`                                                 |
  | `true`    | `true`                                                |
  | `false`   | `false`                                               |
  | string    | `java.lang.String` (decoded; may hold supplementary   |
  |           | characters as surrogate pairs)                        |
  | number    | a [[Num]] holding the canonical text of the number    |
  | array     | a persistent vector of tree values                    |
  | object    | an [[Obj]] holding *all* members in input order,      |
  |           | duplicates included                                   |

  Numbers are never converted to a numeric type, so integers of any size and
  any number of fraction digits survive unchanged.")

(defrecord Num [^String text])

(defrecord Obj [members])

(defn num-node
  "Returns a number node whose canonical text is `text`."
  [^String text]
  (->Num text))

(defn obj-node
  "Returns an object node over `members`, a sequential collection of
  `[key value]` pairs (keys are strings). Order and duplicates are kept."
  [members]
  (->Obj (mapv (fn [[k v]] (clojure.lang.MapEntry/create k v)) members)))

(defn num-node?
  "True if `x` is a number node."
  [x]
  (instance? Num x))

(defn obj-node?
  "True if `x` is an object node."
  [x]
  (instance? Obj x))

(defn number-text
  "The canonical text of number node `n`."
  ^String [^Num n]
  (.text n))

(defn members
  "The `[key value]` members of object node `o`, in input order, duplicates
  included."
  [^Obj o]
  (.members o))
