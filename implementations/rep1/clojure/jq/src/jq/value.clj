(ns jq.value
  "The jq data model: representation, ordering, equality and errors.

  jq values map onto Clojure values as follows:

  | jq      | representation                                   |
  |---------|--------------------------------------------------|
  | null    | `nil`                                            |
  | boolean | `true` / `false`                                 |
  | number  | `java.lang.Double` (always a double)             |
  | string  | `java.lang.String`                               |
  | array   | persistent vector                                |
  | object  | [[JObj]], an insertion-ordered immutable map     |

  Everything is immutable and shared structurally, so passing a value around
  is O(1) whatever its size."
  (:import [java.util Arrays Comparator]
           [clojure.lang IPersistentMap IPersistentVector]))

;; ------------------------------------------------------------- characters

(defmacro ceq
  "True if the char expression `c` is the character literal `ch`."
  [c ch]
  `(== (int ~c) ~(int ch)))

;; ---------------------------------------------------------------- errors

(defn jq-error
  "Builds the exception that represents a jq runtime error carrying `value`
  (the thing `error(value)` raised, or a message string for built-in errors)."
  [value]
  (ex-info (str "jq error: " (if (string? value) value "(not a string)"))
           {::type :error ::value value}))

(defn fail
  "Raises a jq runtime error carrying `value`."
  [value]
  (throw (jq-error value)))

(defn jq-error?
  "True if `e` is a jq runtime error (as opposed to an internal failure)."
  [e]
  (and (instance? clojure.lang.ExceptionInfo e)
       (= :error (::type (ex-data e)))))

(defn error-value
  "The value carried by a jq runtime error."
  [e]
  (::value (ex-data e)))

;; --------------------------------------------------------------- strings

(defn compare-strings
  "Compares two strings by Unicode code point (equivalently by UTF-8 bytes).
  Differs from `String.compareTo` only for surrogate pairs vs. U+E000..U+FFFF."
  ^long [^String a ^String b]
  (let [la (.length a) lb (.length b) n (Math/min la lb)]
    (loop [i 0]
      (if (< i n)
        (let [ca (.charAt a i) cb (.charAt b i)]
          (if (== (int ca) (int cb))
            (recur (inc i))
            (let [sa (Character/isSurrogate ca) sb (Character/isSurrogate cb)]
              (cond
                (and sa (not sb)) (if (>= (int cb) 0xE000) 1 (- (int ca) (int cb)))
                (and sb (not sa)) (if (>= (int ca) 0xE000) -1 (- (int ca) (int cb)))
                :else (- (int ca) (int cb))))))
        (- la lb)))))

(def ^:private ^Comparator string-comparator
  (reify Comparator (compare [_ a b] (compare-strings a b))))

;; --------------------------------------------------------------- objects

(declare compare-values)

(defprotocol ObjectOps
  (obj-sorted-keys [o] "Keys as a vector sorted by code point (computed once).")
  (obj-assoc [o k v] "Sets key `k` to `v`; a new key is appended to the order."))

(deftype JObj [^IPersistentMap m ^IPersistentVector ks ^:volatile-mutable sorted]
  ObjectOps
  (obj-sorted-keys [_]
    (or sorted
        (let [arr (to-array ks)]
          (Arrays/sort arr string-comparator)
          (let [s (vec arr)] (set! sorted s) s))))
  (obj-assoc [_ k v]
    (if (.containsKey m k)
      (JObj. (.assoc m k v) ks sorted)
      (JObj. (.assoc m k v) (.cons ks k) nil)))
  Object
  (equals [this other] (and (instance? JObj other) (zero? (compare-values this other))))
  (hashCode [_] (.hashCode m))
  (toString [_] (str "#jq/object " (pr-str (mapv (fn [k] [k (.valAt m k)]) ks)))))

(defmethod print-method JObj [o ^java.io.Writer w] (.write w (str o)))

(def empty-obj
  "The empty jq object."
  (JObj. {} [] nil))

(defn obj-make
  "Wraps an already-built map `m` and its key order `ks` (a vector holding
  exactly the keys of `m`) as an object. Used by the JSON parser."
  [m ks]
  (JObj. m ks nil))

(defn object?
  "True if `x` is a jq object."
  [x] (instance? JObj x))

(defn obj-get
  "Value under key `k`, or nil (null) if absent."
  [^JObj o k] (.valAt ^IPersistentMap (.-m o) k))

(defn obj-has?
  "True if `o` has key `k`."
  [^JObj o k] (.containsKey ^IPersistentMap (.-m o) k))

(defn obj-keys
  "Keys of `o` in insertion order, as a vector."
  [^JObj o] (.-ks o))

(defn obj-count
  "Number of keys of `o`."
  [^JObj o] (count (.-ks o)))

(defn obj-vals
  "Values of `o` in insertion order, as a vector."
  [^JObj o]
  (let [m ^IPersistentMap (.-m o)]
    (persistent! (reduce (fn [acc k] (conj! acc (.valAt m k))) (transient []) (.-ks o)))))

(defn obj-merge
  "`a + b` on objects: shallow merge, `b` wins, `a`'s key positions kept."
  [a b]
  (reduce (fn [acc k] (obj-assoc acc k (obj-get b k))) a (obj-keys b)))

(defn obj-deep-merge
  "`a * b` on objects: recursive merge."
  [a b]
  (reduce (fn [acc k]
            (let [bv (obj-get b k)
                  av (obj-get acc k)]
              (obj-assoc acc k (if (and (object? av) (object? bv) (obj-has? acc k))
                                 (obj-deep-merge av bv)
                                 bv))))
          a (obj-keys b)))

(defn object
  "Builds a jq object from alternating keys and values, e.g.
  `(object \"a\" 1.0 \"b\" nil)`. Repeated keys keep the first position."
  [& kvs]
  (reduce (fn [o [k v]] (obj-assoc o k v)) empty-obj (partition 2 kvs)))

;; -------------------------------------------------------------- ordering

(defn num?
  "True if `x` is a jq number."
  [x] (instance? Double x))

(defn truthy?
  "jq truthiness: everything except `false` and `null` is true."
  [x] (if x true false))

(defn type-name
  "The jq type name of `x`, as returned by the `type` builtin."
  [x]
  (cond (nil? x) "null"
        (instance? Boolean x) "boolean"
        (instance? Double x) "number"
        (string? x) "string"
        (vector? x) "array"
        (instance? JObj x) "object"
        :else (throw (IllegalArgumentException. (str "not a jq value: " (pr-str x))))))

(defn- rank ^long [x]
  (cond (nil? x) 0
        (instance? Boolean x) (if x 2 1)
        (instance? Double x) 3
        (string? x) 4
        (vector? x) 5
        :else 6))

(defn compare-values
  "Total order over jq values: null < false < true < numbers < strings <
  arrays < objects, then structurally within a type. Returns a negative, zero
  or positive long."
  ^long [a b]
  (if (identical? a b)
    0
    (let [ra (rank a) rb (rank b)]
      (if (not= ra rb)
        (if (< ra rb) -1 1)
        (case ra
          (0 1 2) 0
          3 (let [x (double a) y (double b)] (cond (< x y) -1 (> x y) 1 :else 0))
          4 (compare-strings a b)
          5 (let [^IPersistentVector va a ^IPersistentVector vb b
                  na (.count va) nb (.count vb) n (Math/min na nb)]
              (loop [i 0]
                (if (< i n)
                  (let [c (compare-values (.nth va i) (.nth vb i))]
                    (if (zero? c) (recur (inc i)) c))
                  (- na nb))))
          6 (let [ka (obj-sorted-keys a) kb (obj-sorted-keys b)
                  c (compare-values ka kb)]
              (if (zero? c)
                (loop [i 0]
                  (if (< i (count ka))
                    (let [k (nth ka i)
                          c (compare-values (obj-get a k) (obj-get b k))]
                      (if (zero? c) (recur (inc i)) c))
                    0))
                c)))))))

(defn equal?
  "jq equality: compares equal under [[compare-values]]."
  [a b] (zero? (compare-values a b)))

(def comparator-values
  "A `java.util.Comparator` implementing [[compare-values]]."
  (reify Comparator (compare [_ a b] (compare-values a b))))

;; ------------------------------------------------- Clojure interoperation

(defn from-clj
  "Converts ordinary Clojure data to a jq value: maps become objects (keys
  must be strings or keywords; iteration order is the key order), sequential
  collections become arrays, numbers become doubles."
  [x]
  (cond (nil? x) nil
        (instance? Boolean x) x
        (number? x) (double x)
        (string? x) x
        (keyword? x) (subs (str x) 1)
        (map? x) (reduce-kv (fn [o k v] (obj-assoc o (if (keyword? k) (name k) k) (from-clj v)))
                            empty-obj x)
        (sequential? x) (mapv from-clj x)
        :else (throw (IllegalArgumentException. (str "cannot convert to a jq value: " (pr-str x))))))

(defn to-clj
  "Converts a jq value to plain Clojure data: objects become array-maps with
  string keys (keeping the key order), arrays vectors. Numbers stay doubles."
  [x]
  (cond (vector? x) (mapv to-clj x)
        (object? x) (apply array-map
                           (mapcat (fn [k] [k (to-clj (obj-get x k))]) (obj-keys x)))
        :else x))
