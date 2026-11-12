(ns sitegen.template.value
  "The value model of the template language and the operations on it.

  Template values are plain JVM values:

  | template kind | representation                                   |
  |---------------|--------------------------------------------------|
  | integer       | `Long`                                           |
  | float         | `Double`                                         |
  | boolean       | `Boolean`                                        |
  | none          | `nil`                                            |
  | string        | `String`                                         |
  | list          | any `java.util.List` (e.g. a vector)             |
  | dict          | any `java.util.Map` with string keys; iteration  |
  |               | order is the map's order (use `LinkedHashMap`)   |
  | undefined     | the singleton `undefined`                        |

  Values are never copied: binding, passing and iterating are O(1)."
  (:require [sitegen.util :as util])
  (:import (java.util Collection List Map)))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Errors

(defn error!
  "Throws the template error `kind` (one of :syntax :filter :undefined
  :template :type) with a human-readable `msg`."
  [kind msg]
  (throw (ex-info (str (name kind) " error: " msg)
                  {:type :sitegen.template/error :kind kind})))

;; ---------------------------------------------------------------------------
;; Special values

(deftype Undefined []
  Object
  (toString [_] "undefined"))

(def undefined
  "The undefined value: result of unbound names, missing members, etc."
  (Undefined.))

(defn undefined? [v] (identical? v undefined))

(deftype Macro [name params body scope state])

(deftype BuiltinRange [])
(def range-fn (BuiltinRange.))

(deftype SuperFn [state block-name index])

(defn defined!
  "Returns `v`, or throws an `undefined` error when it is the undefined value."
  [v]
  (if (undefined? v) (error! :undefined "use of an undefined value") v))

;; ---------------------------------------------------------------------------
;; Kinds

(defn number-value? [v]
  (or (instance? Long v) (instance? Double v) (instance? Boolean v)))

(defn- as-number
  "A number (Long or Double) for a Long, Double or Boolean value."
  [v]
  (if (instance? Boolean v) (if ^boolean v 1 0) v))

(defn list-value? [v] (instance? List v))
(defn dict-value? [v] (instance? Map v))

(defn truthy?
  "The truthiness of a defined value; throws for the undefined value."
  [v]
  (cond
    (nil? v) false
    (instance? Boolean v) v
    (instance? Long v) (not (zero? (long v)))
    (instance? Double v) (not (zero? (double v)))
    (string? v) (pos? (.length ^String v))
    (instance? Collection v) (not (.isEmpty ^Collection v))
    (instance? Map v) (not (.isEmpty ^Map v))
    (undefined? v) (error! :undefined "truth value of an undefined value")
    :else true))

;; ---------------------------------------------------------------------------
;; Printing

(defn- float->string
  "Python-style `repr` of a double: shortest round-trip digits, positional
  notation for decimal exponents -4 <= e < 16, otherwise scientific."
  ^String [^double d]
  (cond
    (zero? d) (if (neg? (Math/copySign 1.0 d)) "-0.0" "0.0")
    :else
    (let [neg (neg? d)
          js (Double/toString (Math/abs d))
          epos (.indexOf js (int \E))
          mant (if (neg? epos) js (.substring js 0 epos))
          exp (if (neg? epos) 0 (Long/parseLong (.substring js (inc epos))))
          dot (.indexOf mant (int \.))
          int-part (.substring mant 0 dot)
          all (str int-part (.substring mant (inc dot)))
          lz (count (take-while #(= % \0) all))
          stripped (let [t (.substring all lz)
                         end (loop [e (.length t)] (if (and (> e 1) (= (.charAt t (dec e)) \0)) (recur (dec e)) e))]
                     (.substring t 0 end))
          e10 (+ (- (.length int-part) lz 1) exp)
          digits stripped
          body (if (and (<= -4 e10) (< e10 16))
                 (if (>= e10 0)
                   (let [n (inc e10)
                         padded (if (< (.length digits) n)
                                  (str digits (apply str (repeat (- n (.length digits)) \0)))
                                  digits)]
                     (str (.substring padded 0 n) "."
                          (if (> (.length padded) n) (.substring padded n) "0")))
                   (str "0." (apply str (repeat (- (- e10) 1) \0)) digits))
                 (str (.substring digits 0 1)
                      (when (> (.length digits) 1) (str "." (.substring digits 1)))
                      "e" (if (neg? e10) "-" "+")
                      (let [a (Math/abs (long e10))] (if (< a 10) (str "0" a) (str a)))))]
      (if neg (str "-" body) body))))

(declare to-str repr)

(defn- repr-string ^String [^String s]
  (let [quote (if (and (>= (.indexOf s (int \')) 0) (neg? (.indexOf s (int \")))) \" \')
        sb (StringBuilder. (+ 2 (.length s)))]
    (.append sb quote)
    (dotimes [i (.length s)]
      (let [c (.charAt s i)]
        (cond
          (= c \\) (.append sb "\\\\")
          (= c \newline) (.append sb "\\n")
          (= c \return) (.append sb "\\r")
          (= c \tab) (.append sb "\\t")
          (and (= c quote) (= c \')) (.append sb "\\'")
          :else (.append sb c))))
    (.append sb quote)
    (.toString sb)))

(defn repr
  "The representation of a value inside a printed list or dict."
  ^String [v]
  (if (string? v) (repr-string v) (to-str v)))

(defn to-str
  "The string form of a value, as printed by `{{ ... }}`.  Throws for the
  undefined value."
  ^String [v]
  (cond
    (string? v) v
    (instance? Long v) (Long/toString (long v))
    (instance? Boolean v) (if ^boolean v "True" "False")
    (nil? v) "None"
    (instance? Double v) (float->string (double v))
    (instance? List v) (let [sb (StringBuilder. "[")]
                         (loop [i 0 s (seq v)]
                           (when s
                             (when (pos? i) (.append sb ", "))
                             (.append sb (repr (first s)))
                             (recur (inc i) (next s))))
                         (.append sb "]")
                         (.toString sb))
    (instance? Map v) (let [sb (StringBuilder. "{")
                            first? (volatile! true)]
                        (doseq [^java.util.Map$Entry e (.entrySet ^Map v)]
                          (if @first? (vreset! first? false) (.append sb ", "))
                          (.append sb (repr-string (str (.getKey e))))
                          (.append sb ": ")
                          (.append sb (repr (.getValue e))))
                        (.append sb "}")
                        (.toString sb))
    (undefined? v) (error! :undefined "printing an undefined value")
    :else (str "<" (.getSimpleName (class v)) ">")))

;; ---------------------------------------------------------------------------
;; Sequences, access

(defn code-point-length ^long [^String s] (.codePointCount s 0 (.length s)))

(defn- code-point-strings [^String s]
  (let [n (.length s)]
    (loop [i 0 acc (transient [])]
      (if (< i n)
        (let [cp (.codePointAt s i)
              w (Character/charCount cp)]
          (recur (+ i w) (conj! acc (.substring s i (+ i w)))))
        (persistent! acc)))))

(defn sequence-view
  "The sequence view of a value as a `java.util.List`: a list is itself, a
  dict is the list of its keys, a string is the list of its characters."
  ^List [v]
  (cond
    (instance? List v) v
    (instance? Map v) (vec (.keySet ^Map v))
    (string? v) (code-point-strings v)
    (undefined? v) (error! :undefined "iterating an undefined value")
    :else (error! :type "value is not a sequence")))

(defn get-item
  "`a.key` / `a[key]`: member access on dicts, indexing of lists and strings,
  the undefined value for every miss."
  [a k]
  (when (or (undefined? a) (undefined? k))
    (error! :undefined "member access on an undefined value"))
  (cond
    (and (instance? Map a) (string? k))
    (.getOrDefault ^Map a k undefined)

    (and (instance? List a) (or (instance? Long k) (instance? Boolean k)))
    (let [^List l a
          n (.size l)
          i (long (as-number k))
          i (if (neg? i) (+ i n) i)]
      (if (and (>= i 0) (< i n)) (.get l (int i)) undefined))

    (and (string? a) (or (instance? Long k) (instance? Boolean k)))
    (let [^String s a
          n (code-point-length s)
          i (long (as-number k))
          i (if (neg? i) (+ i n) i)]
      (if (and (>= i 0) (< i n))
        (let [start (.offsetByCodePoints s 0 (int i))
              end (.offsetByCodePoints s start 1)]
          (.substring s start end))
        undefined))

    :else undefined))

;; ---------------------------------------------------------------------------
;; Equality, ordering and operators

(defn equal?
  "The `==` of the language for two defined values."
  [a b]
  (cond
    (and (number-value? a) (number-value? b)) (== (as-number a) (as-number b))
    (and (string? a) (string? b)) (.equals ^String a ^String b)
    (and (instance? List a) (instance? List b))
    (let [^List x a ^List y b n (.size x)]
      (and (== n (.size y))
           (loop [i 0] (or (>= i n) (and (equal? (.get x i) (.get y i)) (recur (inc i)))))))
    (and (instance? Map a) (instance? Map b))
    (let [^Map x a ^Map y b]
      (and (== (.size x) (.size y))
           (every? (fn [^java.util.Map$Entry e]
                     (let [k (.getKey e)]
                       (and (.containsKey y k) (equal? (.getValue e) (.get y k)))))
                   (.entrySet x))))
    (and (nil? a) (nil? b)) true
    :else false))

(defn- type-error! [msg] (error! :type msg))

(defn- both-defined! [a b]
  (when (or (undefined? a) (undefined? b))
    (error! :undefined "operand is an undefined value")))

(defn- double-value? [x] (instance? Double x))

(defn add [a b]
  (both-defined! a b)
  (cond
    (and (number-value? a) (number-value? b))
    (let [x (as-number a) y (as-number b)]
      (if (or (double-value? x) (double-value? y)) (+ (double x) (double y)) (+ (long x) (long y))))
    (and (string? a) (string? b)) (str a b)
    (and (instance? List a) (instance? List b)) (into (vec a) b)
    :else (type-error! "unsupported operands for +")))

(defn negate [a]
  (defined! a)
  (if (number-value? a)
    (let [x (as-number a)] (if (double-value? x) (- (double x)) (- (long x))))
    (type-error! "unsupported operand for unary -")))

(defn subtract [a b]
  (both-defined! a b)
  (if (and (number-value? a) (number-value? b))
    (let [x (as-number a) y (as-number b)]
      (if (or (double-value? x) (double-value? y)) (- (double x) (double y)) (- (long x) (long y))))
    (type-error! "unsupported operands for -")))

(defn multiply [a b]
  (both-defined! a b)
  (cond
    (and (number-value? a) (number-value? b))
    (let [x (as-number a) y (as-number b)]
      (if (or (double-value? x) (double-value? y)) (* (double x) (double y)) (* (long x) (long y))))
    (and (string? a) (or (instance? Long b) (instance? Boolean b)))
    (let [n (long (as-number b))] (if (pos? n) (apply str (repeat n a)) ""))
    (and (string? b) (or (instance? Long a) (instance? Boolean a)))
    (let [n (long (as-number a))] (if (pos? n) (apply str (repeat n b)) ""))
    :else (type-error! "unsupported operands for *")))

(defn divide [a b]
  (both-defined! a b)
  (if (and (number-value? a) (number-value? b))
    (let [y (double (as-number b))]
      (when (zero? y) (type-error! "division by zero"))
      (/ (double (as-number a)) y))
    (type-error! "unsupported operands for /")))

(defn- fmod
  "Exact C-style fmod of two doubles (Clojure's `rem` is imprecise)."
  ^double [^double x ^double y]
  (if (or (Double/isInfinite x) (Double/isNaN x) (Double/isInfinite y) (Double/isNaN y))
    (rem x y)
    (.doubleValue (.remainder (BigDecimal. x) (BigDecimal. y)))))

(defn- float-divmod
  "Python's float divmod: [floor-quotient modulo] with the sign of `y`."
  [^double x ^double y]
  (let [m (fmod x y)
        div (/ (- x m) y)
        [div m] (cond
                  (zero? m) [div (Math/copySign 0.0 y)]
                  (not= (neg? y) (neg? m)) [(- div 1.0) (+ m y)]
                  :else [div m])
        q (if (zero? div)
            (Math/copySign 0.0 (/ x y))
            (let [fl (Math/floor div)]
              (if (> (- div fl) 0.5) (+ fl 1.0) fl)))]
    [q m]))

(defn floor-divide [a b]
  (both-defined! a b)
  (if (and (number-value? a) (number-value? b))
    (let [x (as-number a) y (as-number b)]
      (when (zero? (double y)) (type-error! "division by zero"))
      (if (or (double-value? x) (double-value? y))
        (first (float-divmod (double x) (double y)))
        (Math/floorDiv (long x) (long y))))
    (type-error! "unsupported operands for //")))

(defn modulo [a b]
  (both-defined! a b)
  (if (and (number-value? a) (number-value? b))
    (let [x (as-number a) y (as-number b)]
      (when (zero? (double y)) (type-error! "modulo by zero"))
      (if (or (double-value? x) (double-value? y))
        (second (float-divmod (double x) (double y)))
        (Math/floorMod (long x) (long y))))
    (type-error! "unsupported operands for %")))

(defn power [a b]
  (both-defined! a b)
  (if (and (number-value? a) (number-value? b))
    (let [x (as-number a) y (as-number b)]
      (cond
        (or (double-value? x) (double-value? y))
        (do (when (and (zero? (double x)) (neg? (double y))) (type-error! "0 cannot be raised to a negative power"))
            (Math/pow (double x) (double y)))

        (neg? (long y))
        (do (when (zero? (long x)) (type-error! "0 cannot be raised to a negative power"))
            (Math/pow (double x) (double y)))

        :else (.longValue (.pow (BigInteger/valueOf (long x)) (int y)))))
    (type-error! "unsupported operands for **")))

(defn concat-str
  "The `~` operator."
  [a b]
  (str (to-str a) (to-str b)))

(defn- order [a b op-name]
  (both-defined! a b)
  (cond
    (and (number-value? a) (number-value? b)) (compare (as-number a) (as-number b))
    (and (string? a) (string? b)) (util/compare-code-points a b)
    :else (type-error! (str "unsupported operands for " op-name))))

(defn less? [a b] (neg? (long (order a b "<"))))
(defn less-equal? [a b] (not (pos? (long (order a b "<=")))))
(defn greater? [a b] (pos? (long (order a b ">"))))
(defn greater-equal? [a b] (not (neg? (long (order a b ">=")))))

(defn equals? [a b]
  (both-defined! a b)
  (equal? a b))

(defn contains-value?
  "`needle in haystack`."
  [needle haystack]
  (both-defined! needle haystack)
  (cond
    (string? haystack)
    (if (string? needle)
      (<= 0 (.indexOf ^String haystack ^String needle))
      (type-error! "'in <string>' requires a string"))

    (instance? Map haystack)
    (and (string? needle) (.containsKey ^Map haystack needle))

    (instance? List haystack)
    (boolean (some #(equal? needle %) haystack))

    :else (type-error! "argument of type is not iterable")))
