(ns depresolve.version
  "Semantic versions, packed into a single `long` so that numeric ordering of
  versions is plain `long` ordering.

  A version `MAJOR.MINOR.PATCH` (each component at most 1,000,000 < 2^20) is
  encoded as `MAJOR<<40 | MINOR<<20 | PATCH`.  Because the encoding is
  monotonic, `v+1` is the immediate successor of `v`, which makes inclusive
  upper bounds easy to express as exclusive ones.")

(set! *warn-on-reflection* true)

(def ^:const ^long component-bits 20)
(def ^:const ^long component-mask (dec (bit-shift-left 1 component-bits)))

(defn pack
  "Packs three non-negative integer components into a version `long`."
  ^long [^long major ^long minor ^long patch]
  (bit-or (bit-shift-left major (* 2 component-bits))
          (bit-shift-left minor component-bits)
          patch))

(defn major ^long [^long v] (bit-shift-right v (* 2 component-bits)))
(defn minor ^long [^long v] (bit-and (bit-shift-right v component-bits) component-mask))
(defn patch ^long [^long v] (bit-and v component-mask))

(defn parse
  "Parses the string `\"X.Y.Z\"` into a packed version `long`."
  ^long [^String s]
  (let [d1 (.indexOf s ".")
        d2 (.indexOf s "." (unchecked-inc-int d1))]
    (pack (Long/parseLong (.substring s 0 d1))
          (Long/parseLong (.substring s (unchecked-inc-int d1) d2))
          (Long/parseLong (.substring s (unchecked-inc-int d2))))))

(defn fmt
  "Formats a packed version `long` as `\"X.Y.Z\"`."
  ^String [^long v]
  (str (major v) \. (minor v) \. (patch v)))
