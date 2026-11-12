(ns sat.clause
  "Clause objects stored by the solver.")

(definterface IClause
  (^double activity [])
  (setActivity [^double a])
  (^boolean dead [])
  (markDead []))

(deftype Clause [^ints lits
                 ^boolean learnt
                 ^:unsynchronized-mutable ^double act
                 ^:unsynchronized-mutable ^boolean dead?]
  IClause
  (activity [_] act)
  (setActivity [_ a] (set! act a))
  (dead [_] dead?)
  (markDead [_] (set! dead? (boolean true))))

(defn make-clause
  "Creates a clause over the internal literal codes in `lits` (an int array)."
  ^Clause [^ints lits learnt?]
  (->Clause lits (boolean learnt?) 0.0 false))
