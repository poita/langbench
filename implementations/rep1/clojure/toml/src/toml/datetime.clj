(ns toml.datetime
  "Date and time literals.  They are validated and canonicalised purely as
  text; there is no calendar arithmetic and no time zone conversion."
  (:require [toml.data :as d]))

(set! *warn-on-reflection* true)

(defn- code ^long [^String s ^long i]
  (if (< i (.length s)) (long (int (.charAt s i))) -1))

(defn- digits
  "Value of the `n` ASCII digits at `i`, or -1."
  ^long [^String s ^long i ^long n]
  (loop [k 0 acc 0]
    (if (== k n)
      acc
      (let [c (code s (+ i k))]
        (if (and (>= c 48) (<= c 57))
          (recur (unchecked-inc k) (+ (* acc 10) (- c 48)))
          -1)))))

(defn- leap? [^long y]
  (and (zero? (rem y 4)) (or (pos? (rem y 100)) (zero? (rem y 400)))))

(defn- days-in-month ^long [^long y ^long m]
  (case m
    2 (if (leap? y) 29 28)
    (4 6 9 11) 30
    31))

(defn- strip-zeros ^String [^String frac]
  (loop [e (.length frac)]
    (if (and (pos? e) (== (code frac (dec e)) 48)) (recur (dec e)) (subs frac 0 e))))

(defn- scan-time
  "Scans `HH:MM:SS[.frac]` at `i`.  Returns `[canonical-text end]` or nil."
  [^String s ^long i]
  (let [h (digits s i 2) m (digits s (+ i 3) 2) sec (digits s (+ i 6) 2)]
    (when (and (<= 0 h 23) (<= 0 m 59) (<= 0 sec 59)
               (== (code s (+ i 2)) 58) (== (code s (+ i 5)) 58))
      (let [j (+ i 8) base (subs s i j)]
        (if (== (code s j) 46)
          (let [k (loop [k (inc j)]
                    (let [c (code s k)] (if (and (>= c 48) (<= c 57)) (recur (inc k)) k)))]
            (when (> k (inc j))
              (let [frac (strip-zeros (subs s (inc j) k))]
                [(if (.isEmpty frac) base (str base "." frac)) k])))
          [base j])))))

(defn- scan-offset
  "Scans an optional offset at `i`.  Returns `[text end]` (text nil when there
  is none) or nil when an offset is present but invalid."
  [^String s ^long i]
  (let [c (code s i)]
    (cond
      (or (== c 90) (== c 122)) ["Z" (inc i)]
      (or (== c 43) (== c 45))
      (let [h (digits s (inc i) 2) m (digits s (+ i 4) 2)]
        (when (and (<= 0 h 23) (<= 0 m 59) (== (code s (+ i 3)) 58))
          [(if (and (zero? h) (zero? m)) "Z" (subs s i (+ i 6))) (+ i 6)]))
      :else [nil i])))

(defn scan
  "Scans a date, time or date-time literal starting at index `i` of `s`.
  Returns `[scalar end-index]`, or nil when the text there is not a valid
  literal.  A space separates a date from a time only when a complete time
  follows it; otherwise the literal is a local date."
  [^String s ^long i]
  (if (== (code s (+ i 2)) 58)
    (when-let [[t j] (scan-time s i)]
      [(d/scalar :time-local t) j])
    (let [y (digits s i 4) mo (digits s (+ i 5) 2) dd (digits s (+ i 8) 2)]
      (when (and (>= y 1) (<= 1 mo 12) (<= 1 dd (days-in-month y mo))
                 (== (code s (+ i 4)) 45) (== (code s (+ i 7)) 45))
        (let [date (subs s i (+ i 10)) j (+ i 10) c (code s j)]
          (if (or (== c 84) (== c 116) (== c 32))
            (if-let [[t k] (scan-time s (inc j))]
              (when-let [[off end] (scan-offset s k)]
                [(if off
                   (d/scalar :datetime (str date "T" t off))
                   (d/scalar :datetime-local (str date "T" t)))
                 end])
              (when (== c 32) [(d/scalar :date-local date) j]))
            [(d/scalar :date-local date) j]))))))
