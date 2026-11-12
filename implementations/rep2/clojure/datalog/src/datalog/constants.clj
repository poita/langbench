(ns datalog.constants
  "The total order on constants and the interning of constants as ranks.

  A constant is a `Long` (integer) or a `String` (identifier).  Every integer
  sorts before every identifier; integers compare numerically; identifiers
  compare by ASCII value with a proper prefix first.

  The evaluator never compares constants directly.  Once the whole program is
  known, [[intern-table]] sorts the distinct constants once and replaces each
  by its *rank* (a `long`), so equality, comparison built-ins and output
  ordering are all plain integer operations on ranks.")

(set! *warn-on-reflection* true)

(defn compare-constants
  "Comparator implementing the total order on constants."
  [a b]
  (if (instance? Long a)
    (if (instance? Long b) (compare ^long a ^long b) -1)
    (if (instance? Long b) 1 (compare ^String a ^String b))))

(defn intern-table
  "Builds an intern table for the collection of constants `cs`.

  Returns `{:rank {constant -> long}, :constants [constant ...]}` where
  `:constants` is the vector of distinct constants in ascending order, so that
  `(get-in table [:constants rank])` inverts `(get-in table [:rank c])`."
  [cs]
  (let [sorted (vec (sort compare-constants (distinct cs)))]
    {:constants sorted
     :rank (persistent!
            (reduce-kv (fn [m i c] (assoc! m c (long i)))
                       (transient {})
                       sorted))}))

(defn format-constant
  "Canonical text of a constant: decimal for integers, the name otherwise."
  ^String [c]
  (if (string? c) c (str c)))
