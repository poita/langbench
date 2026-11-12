(ns softfloat.add
  "binary32 addition and subtraction."
  (:require [softfloat.fields :as f]
            [softfloat.round :as r]))

(set! *warn-on-reflection* true)

(def ^:private ^:const guard-bits
  "Extra low-order bits carried by the aligned significands."
  6)

(defn- align
  "Shift `m` right by `d` bits, OR-ing everything shifted out into bit 0
  (a sticky bit)."
  ^long [^long m ^long d]
  (cond
    (zero? d) m
    (>= d 63) 1
    :else (let [lost (bit-and m (dec (bit-shift-left 1 d)))]
            (bit-or (bit-shift-right m d) (if (zero? lost) 0 1)))))

(defn add
  "Sum of binary32 patterns `a` and `b`, as a pattern."
  ^long [^long a ^long b]
  (cond
    (or (f/nan? a) (f/nan? b)) f/quiet-nan

    (f/infinite? a)
    (if (and (f/infinite? b) (not= (f/sign a) (f/sign b)))
      f/quiet-nan
      a)

    (f/infinite? b) b

    (f/zero? a)
    (if (f/zero? b)
      (f/pack-zero (bit-and (f/sign a) (f/sign b)))
      b)

    (f/zero? b) a

    :else
    (let [sa (f/sign a)
          sb (f/sign b)
          [^long ma ^long ea] (f/unpack a)
          [^long mb ^long eb] (f/unpack b)
          ;; Order so that x has the larger (or equal) exponent.
          swap? (< ea eb)
          [^long mx ^long ex ^long sx ^long my ^long ey ^long sy]
          (if swap? [mb eb sb ma ea sa] [ma ea sa mb eb sb])
          mx (bit-shift-left mx guard-bits)
          my (align (bit-shift-left my guard-bits) (- ex ey))
          e  (- ex guard-bits)]
      (if (== sx sy)
        (r/round-pack sx (+ mx my) e false)
        (let [d (- mx my)]
          (cond
            (zero? d) (f/pack-zero 0)
            (pos? d)  (r/round-pack sx d e false)
            :else     (r/round-pack sy (- d) e false)))))))

(defn sub
  "Difference `a - b` of binary32 patterns, as a pattern: `a + (-b)`."
  ^long [^long a ^long b]
  (add a (f/negate b)))
