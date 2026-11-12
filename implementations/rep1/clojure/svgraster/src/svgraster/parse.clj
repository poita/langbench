(ns svgraster.parse
  "Parsers for the small attribute micro-syntaxes of SVG: numbers, lengths,
  opacities, number lists, transform lists and `style` declarations."
  (:require [clojure.string :as str]
            [svgraster.matrix :as m]))

(set! *warn-on-reflection* true)

(defn- digit? [c] (and (char? c) (<= (int \0) (int c) (int \9))))

(defn- digits-end
  "Index after the run of decimal digits starting at `i`."
  ^long [^String s ^long i]
  (let [n (.length s)]
    (loop [i i]
      (if (and (< i n) (digit? (.charAt s i))) (recur (inc i)) i))))

(defn scan-number
  "Returns the index just past the number that starts at index `i` of `s`, or
  -1 when no number starts there. Grammar: optional sign, digits with an
  optional `.fraction` (at least one digit overall), optional exponent."
  ^long [^String s ^long i]
  (let [n (.length s)
        j (if (and (< i n) (let [c (.charAt s i)] (or (= c \+) (= c \-)))) (inc i) i)
        k (digits-end s j)
        int-digits (- k j)
        [k frac-digits] (if (and (< k n) (= (.charAt s k) \.))
                          (let [e (digits-end s (inc k))] [e (- e (inc k))])
                          [k 0])]
    (if (zero? (+ int-digits (long frac-digits)))
      -1
      (if (and (< k n) (let [c (.charAt s k)] (or (= c \e) (= c \E))))
        (let [p (inc k)
              p (if (and (< p n) (let [c (.charAt s p)] (or (= c \+) (= c \-)))) (inc p) p)
              q (digits-end s p)]
          (if (> q p) q k))
        k))))

(defn parse-number-at
  "Reads the number starting exactly at index `i`; returns `[value end]` or
  nil."
  [^String s ^long i]
  (let [e (scan-number s i)]
    (when (>= e 0)
      [(Double/parseDouble (subs s i e)) e])))

(defn skip-separators
  "Index of the first character at or after `i` that is not whitespace or a
  comma."
  ^long [^String s ^long i]
  (let [n (.length s)]
    (loop [i i]
      (if (and (< i n)
               (let [c (.charAt s i)]
                 (or (= c \space) (= c \tab) (= c \newline) (= c \return) (= c \,)
                     (= c \formfeed))))
        (recur (inc i))
        i))))

(defn- skip-ws ^long [^String s ^long i]
  (let [n (.length s)]
    (loop [i i]
      (if (and (< i n) (Character/isWhitespace (.charAt s i))) (recur (inc i)) i))))

(defn parse-number
  "Parses a leading number of `s` (after optional whitespace); nil if there is
  none. Anything after the number is ignored."
  [s]
  (when s
    (let [^String s s]
      (first (parse-number-at s (skip-ws s 0))))))

(defn parse-length
  "Parses a length: a number optionally followed by `px`. Returns a double, or
  nil when `s` is nil or does not start with a number."
  [s]
  (parse-number s))

(defn parse-opacity
  "Parses an opacity: a number or a percentage, clamped to [0, 1]. Returns nil
  when `s` is not of that form."
  [s]
  (when s
    (let [^String s (str/trim s)]
      (when-let [[v e] (parse-number-at s 0)]
        (let [rest (subs s e)]
          (cond
            (= rest "") (Math/max 0.0 (Math/min 1.0 (double v)))
            (= rest "%") (Math/max 0.0 (Math/min 1.0 (/ (double v) 100.0)))
            :else nil))))))

(defn parse-number-list
  "Parses numbers separated by whitespace and/or commas, stopping at the first
  token that is not a number. Returns a vector of doubles."
  [^String s]
  (loop [i (skip-separators s 0) acc (transient [])]
    (if-let [[v e] (and (< i (.length s)) (parse-number-at s i))]
      (recur (skip-separators s e) (conj! acc v))
      (persistent! acc))))

(defn- transform-function
  "The matrix of one transform function, or nil when it is unknown or has too
  few arguments."
  [name args]
  (let [n (count args)
        [a b c d e f] args]
    (case name
      "matrix" (when (>= n 6) (mapv double [a b c d e f]))
      "translate" (when (>= n 1) (m/translate a (or b 0.0)))
      "scale" (when (>= n 1) (m/scale a (or b a)))
      "rotate" (when (>= n 1)
                 (let [r (m/rotate a)]
                   (if (>= n 3)
                     (m/multiply (m/translate b c) (m/multiply r (m/translate (- (double b)) (- (double c)))))
                     r)))
      "skewX" (when (>= n 1) [1.0 0.0 (Math/tan (Math/toRadians (double a))) 1.0 0.0 0.0])
      "skewY" (when (>= n 1) [1.0 (Math/tan (Math/toRadians (double a))) 0.0 1.0 0.0 0.0])
      nil)))

(defn parse-transform
  "Parses a `transform` attribute value into a matrix (see `svgraster.matrix`).
  Functions compose left to right; unknown or malformed functions are
  skipped. nil gives the identity."
  [s]
  (if-not s
    m/identity-matrix
    (let [^String s s
          n (.length s)]
      (loop [i (skip-separators s 0) acc m/identity-matrix]
        (if (>= i n)
          acc
          (let [j (loop [j i]
                    (if (and (< j n) (Character/isLetter (.charAt s j))) (recur (inc j)) j))
                name (subs s i j)
                k (skip-ws s j)]
            (if (or (= j i) (>= k n) (not= (.charAt s k) \())
              acc
              (let [close (.indexOf s ")" (int k))
                    end (if (neg? close) n close)
                    args (parse-number-list (subs s (inc k) end))
                    f (transform-function name args)]
                (recur (skip-separators s (min n (inc end)))
                       (if f (m/multiply acc f) acc))))))))))

(defn parse-style
  "Parses a `style` attribute into a map of lower-cased property name to
  trimmed value. Declarations without a `:` or with an empty name or value are
  dropped; later declarations override earlier ones."
  [s]
  (if-not s
    {}
    (reduce (fn [acc ^String decl]
              (let [i (.indexOf decl ":")]
                (if (neg? i)
                  acc
                  (let [k (str/lower-case (str/trim (subs decl 0 i)))
                        v (str/trim (subs decl (inc i)))]
                    (if (or (empty? k) (empty? v)) acc (assoc acc k v))))))
            {}
            (str/split ^String s #";"))))
