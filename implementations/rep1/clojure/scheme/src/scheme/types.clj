(ns scheme.types
  "Runtime data representations shared by every other namespace.

  Scheme value      Clojure/JVM representation
  ---------------   ------------------------------------------------------
  integer           `java.lang.Long`, or `scheme.number.Bignum` outside the
                    64-bit range (always normalised: never a Bignum that fits)
  boolean           `java.lang.Boolean`
  string            `java.lang.String` (immutable)
  symbol            `Sym`, interned: equal names are the same object
  pair              `Pair`
  empty list        the singleton `NIL`
  void              the singleton `VOID`
  closure           `Closure`
  primitive         `Primitive`

  Environments are chains of `Frame`s ending in a global `java.util.HashMap`."
  (:import [java.util Arrays]
           [java.util.concurrent ConcurrentHashMap]))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Atoms

(deftype Sym [^String name]
  Object
  (toString [_] name))

(def ^:private ^ConcurrentHashMap symbol-table (ConcurrentHashMap.))

(defn intern-sym
  "Return the unique `Sym` called `s`."
  ^Sym [^String s]
  (or (.get symbol-table s)
      (let [fresh (Sym. s)]
        (or (.putIfAbsent symbol-table s fresh) fresh))))

(deftype EmptyList [])
(deftype VoidValue [])

(def NIL "The empty list." (EmptyList.))
(def VOID "The value of `define`, `display`, a one-armed false `if`, ..." (VoidValue.))

(deftype Pair [car cdr])

(defn cons-pair [a d] (Pair. a d))

(defn nil-obj? [x] (instance? EmptyList x))
(defn pair? [x] (instance? Pair x))
(defn void? [x] (instance? VoidValue x))

(defn truthy? "Only `#f` is false." [x] (not (false? x)))

;; ---------------------------------------------------------------------------
;; List helpers

(defn vector->list
  "Build a Scheme list from the elements of `coll`, ending in `tail`
  (default `NIL`)."
  ([coll] (vector->list coll NIL))
  ([coll tail]
   (reduce (fn [acc x] (Pair. x acc)) tail (reverse coll))))

(defn array->list
  "Scheme list of the elements of `arr` from index `start` on."
  [^objects arr ^long start]
  (loop [i (dec (alength arr)) acc NIL]
    (if (< i start)
      acc
      (recur (dec i) (Pair. (aget arr i) acc)))))

(defn list->vector
  "Elements of the proper Scheme list `lst` as a Clojure vector, or `nil` if
  `lst` is not a proper list."
  [lst]
  (loop [l lst acc (transient [])]
    (cond
      (instance? Pair l) (recur (.cdr ^Pair l) (conj! acc (.car ^Pair l)))
      (nil-obj? l) (persistent! acc)
      :else nil)))

;; ---------------------------------------------------------------------------
;; Errors

(defn scheme-error
  "An exception representing the runtime error `category`, a keyword such as
  :type-error."
  [category]
  (ex-info (str "scheme error: " (name category)) {:scheme/error category}))

(defn error-category
  "The category keyword of an exception made by `scheme-error`, else nil."
  [^Throwable e]
  (:scheme/error (ex-data e)))

(defn type-error! [] (throw (scheme-error :type-error)))
(defn arity-error! [] (throw (scheme-error :arity-error)))

;; ---------------------------------------------------------------------------
;; Analysed code

(definterface Node
  (ev [env]
    "Evaluate this node in `env` (a Frame, or nil for the global
    environment). A node in tail position may return a `TailCall`."))

(deftype TailCall [f ^objects args])

;; ---------------------------------------------------------------------------
;; Procedures

(deftype Closure [^objects params ^long nreq ^boolean variadic ^Node body env])

(deftype Primitive [^String name ^long min-args ^long max-args f])

(defn procedure? [x] (or (instance? Closure x) (instance? Primitive x)))

;; ---------------------------------------------------------------------------
;; Environment frames

(definterface IFrame
  (getLocal [s] "Value bound to `s` in this frame, or nil.")
  (setLocal [s v] "Assign an existing binding; true if there was one.")
  (defineLocal [s v] "Bind or rebind `s` in this frame."))

(deftype Frame [^:unsynchronized-mutable ^objects syms
                ^:unsynchronized-mutable ^objects vals
                ^:unsynchronized-mutable ^long n
                parent]
  IFrame
  (getLocal [_ s]
    (loop [i 0]
      (if (< i n)
        (if (identical? (aget syms i) s) (aget vals i) (recur (inc i)))
        nil)))
  (setLocal [_ s v]
    (loop [i 0]
      (if (< i n)
        (if (identical? (aget syms i) s)
          (do (aset vals i v) true)
          (recur (inc i)))
        false)))
  (defineLocal [_ s v]
    (loop [i 0]
      (if (< i n)
        (if (identical? (aget syms i) s) (aset vals i v) (recur (inc i)))
        (do
          ;; `syms` may be shared with a closure, so grow by copying.
          (when (== n (alength syms))
            (let [cap (max 4 (* 2 n))]
              (set! syms (Arrays/copyOf syms (int cap)))
              (set! vals (Arrays/copyOf vals (int cap)))))
          (aset syms n s)
          (aset vals n v)
          (set! n (inc n))
          nil)))))

(defn make-frame
  "A frame binding the symbols `syms` to `vals` (arrays of equal length)."
  ^Frame [^objects syms ^objects vals parent]
  (Frame. syms vals (alength syms) parent))

(defn empty-frame
  "A frame with no bindings yet but room for `capacity` of them."
  ^Frame [^long capacity parent]
  (Frame. (object-array capacity) (object-array capacity) 0 parent))
