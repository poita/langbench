(ns buildsys.builtins
  "The 39 built-in functions of KBL.

  [[call]] performs a call in the exact order the specification fixes: look up
  the name, (the caller evaluates the arguments), check the arity, check the
  argument types in ascending order, then run the function."
  (:require [buildsys.error :as err]
            [buildsys.glob :as glob]
            [buildsys.path :as path]
            [buildsys.value :as v]
            [buildsys.vfs :as vfs]))

(set! *warn-on-reflection* true)

(def ^:private type-preds
  {:str [string? "str"]
   :int [integer? "int"]
   :bool [boolean? "bool"]
   :list [vector? "list"]
   :any [(constantly true) "any"]
   :str|list [#(or (string? %) (vector? %)) "str|list"]
   :str|int [#(or (string? %) (integer? %)) "str|int"]
   :str|int|bool [#(or (string? %) (integer? %) (boolean? %)) "str|int|bool"]})

(defonce ^:private registry (atom {}))

(defmacro ^:private defbuiltin
  "Register built-in `fname` with argument types `types` (keywords from
  `type-preds`) and body `(fn [ctx a b ...] ...)`."
  [fname types f]
  `(swap! registry assoc ~fname {:types ~types :fn ~f}))

(defn- window
  "The `[start end)` window for `substr`/`slice` over `n` items."
  [n start cnt]
  (let [start (if (neg? start) (+ n start) start)
        start (max 0 (min n start))
        cnt (max 0 (min cnt (- n start)))]
    [start (+ start cnt)]))

(defn- ascii-map
  [^String s lo hi delta]
  (let [n (.length s)
        sb (StringBuilder. n)]
    (dotimes [i n]
      (let [c (.charAt s i)]
        (.append sb (if (<= (int lo) (int c) (int hi)) (char (+ (int c) (int delta))) c))))
    (str sb)))

(defn- trim-byte? [c] (or (= c \space) (= c \tab) (= c \newline) (= c \return)))

(defn trim-bytes [^String s]
  (let [n (.length s)
        b (loop [i 0] (if (and (< i n) (trim-byte? (.charAt s i))) (recur (inc i)) i))
        e (loop [j n] (if (and (> j b) (trim-byte? (.charAt s (dec j)))) (recur (dec j)) j))]
    (subs s b e)))

(defn split-bytes
  "Split `s` at every occurrence of non-empty `sep`."
  [^String s ^String sep]
  (let [m (.length sep)]
    (loop [from 0 out (transient [])]
      (let [i (.indexOf s sep (int from))]
        (if (neg? i)
          (persistent! (conj! out (subs s from)))
          (recur (+ i m) (conj! out (subs s from i))))))))

(defn- last-index [^String s c] (.lastIndexOf s (int c)))

(defn basename [^String s]
  (let [i (last-index s \/)] (if (neg? i) s (subs s (inc i)))))

(defn- dot-index
  "Index of the last `.` in basename `b` that is not at index 0, or -1."
  [^String b]
  (let [i (last-index b \.)] (if (pos? i) i -1)))

(defn- compile-or-fail [fname pattern]
  (or (glob/compile-pattern pattern)
      (err/fail "E_ARG" (str "fn " fname ": bad pattern"))))

(defn- str-elements [fname xs]
  (doseq [[i x] (map-indexed vector xs)]
    (when-not (string? x) (v/type-error (str "fn " fname " element " i) "str" x))))

(defn- map-pattern [^String pat ^String elem]
  (let [n (.length pat) sb (StringBuilder.)]
    (loop [i 0]
      (when (< i n)
        (let [c (.charAt pat i)]
          (if (= c \%)
            (if (and (< (inc i) n) (= \% (.charAt pat (inc i))))
              (do (.append sb \%) (recur (+ i 2)))
              (do (.append sb elem) (recur (inc i))))
            (do (.append sb c) (recur (inc i)))))))
    (str sb)))

(defbuiltin "len" [:str|list] (fn [_ x] (long (count x))))
(defbuiltin "count" [:list] (fn [_ x] (long (count x))))
(defbuiltin "upper" [:str] (fn [_ s] (ascii-map s \a \z -32)))
(defbuiltin "lower" [:str] (fn [_ s] (ascii-map s \A \Z 32)))
(defbuiltin "trim" [:str] (fn [_ s] (trim-bytes s)))
(defbuiltin "replace" [:str :str :str]
  (fn [_ ^String s ^String from ^String to]
    (when (.isEmpty from) (err/fail "E_ARG" "fn replace: empty pattern"))
    (.replace s from to)))
(defbuiltin "starts_with" [:str :str] (fn [_ ^String s ^String p] (.startsWith s p)))
(defbuiltin "ends_with" [:str :str] (fn [_ ^String s ^String p] (.endsWith s p)))
(defbuiltin "contains" [:str :str] (fn [_ ^String s ^String p] (.contains s p)))
(defbuiltin "substr" [:str :int :int]
  (fn [_ s start cnt]
    (let [[b e] (window (count s) start cnt)] (subs s b e))))
(defbuiltin "split" [:str :str]
  (fn [_ s ^String sep]
    (when (.isEmpty sep) (err/fail "E_ARG" "fn split: empty separator"))
    (split-bytes s sep)))
(defbuiltin "join" [:list :str]
  (fn [_ xs ^String sep]
    (let [sb (StringBuilder.)]
      (doseq [[i x] (map-indexed vector xs)]
        (when-not (or (string? x) (integer? x))
          (v/type-error (str "fn join element " i) "str|int" x))
        (when (pos? i) (.append sb sep))
        (.append sb (if (string? x) ^String x (str x))))
      (str sb))))
(defbuiltin "str" [:str|int|bool] (fn [_ x] (v/to-text x)))
(defbuiltin "int" [:str|int]
  (fn [_ x]
    (if (integer? x)
      x
      (if (re-matches #"-?[0-9]+" x)
        (try (Long/parseLong ^String x)
             (catch NumberFormatException _ (err/fail "E_ARG" "fn int: bad integer")))
        (err/fail "E_ARG" "fn int: bad integer")))))
(defbuiltin "dirname" [:str]
  (fn [_ ^String s] (let [i (last-index s \/)] (if (neg? i) "" (subs s 0 i)))))
(defbuiltin "basename" [:str] (fn [_ s] (basename s)))
(defbuiltin "stem" [:str]
  (fn [_ s] (let [b (basename s) i (dot-index b)] (if (neg? i) b (subs b 0 i)))))
(defbuiltin "ext" [:str]
  (fn [_ s] (let [b (basename s) i (dot-index b)] (if (neg? i) "" (subs b i)))))
(defbuiltin "map" [:list :str]
  (fn [_ xs pat]
    (str-elements "map" xs)
    (mapv #(map-pattern pat %) xs)))
(defbuiltin "filter" [:list :str]
  (fn [_ xs pat]
    (let [g (compile-or-fail "filter" pat)]
      (str-elements "filter" xs)
      (filterv #(glob/matches? g %) xs))))
(defbuiltin "reject" [:list :str]
  (fn [_ xs pat]
    (let [g (compile-or-fail "reject" pat)]
      (str-elements "reject" xs)
      (filterv #(not (glob/matches? g %)) xs))))
(defbuiltin "sort" [:list] (fn [_ xs] (vec (sort v/compare-values xs))))
(defbuiltin "uniq" [:list] (fn [_ xs] (vec (distinct xs))))
(defbuiltin "reverse" [:list] (fn [_ xs] (vec (rseq xs))))
(defbuiltin "first" [:list]
  (fn [_ xs] (if (empty? xs) (err/fail "E_ARG" "fn first: empty list") (nth xs 0))))
(defbuiltin "last" [:list]
  (fn [_ xs] (if (empty? xs) (err/fail "E_ARG" "fn last: empty list") (peek xs))))
(defbuiltin "slice" [:list :int :int]
  (fn [_ xs start cnt]
    (let [[b e] (window (count xs) start cnt)] (subvec xs b e))))
(defbuiltin "has" [:list :any]
  (fn [_ xs x] (boolean (some #(= x %) xs))))
(defbuiltin "indexof" [:list :any]
  (fn [_ xs x]
    (long (or (first (keep-indexed (fn [i y] (when (= x y) i)) xs)) -1))))
(defbuiltin "range" [:int]
  (fn [_ n]
    (when (neg? n) (err/fail "E_ARG" "fn range: negative"))
    (vec (range n))))
(defbuiltin "sum" [:list]
  (fn [_ xs]
    (reduce (fn [acc [i x]]
              (when-not (integer? x) (v/type-error (str "fn sum element " i) "int" x))
              (unchecked-add (long acc) (long x)))
            0
            (map-indexed vector xs))))
(defbuiltin "flatten" [:list]
  (fn [_ xs] (reduce (fn [acc x] (if (vector? x) (into acc x) (conj acc x))) [] xs)))
(defbuiltin "zip" [:list :list]
  (fn [_ as bs] (mapv vector as bs)))
(defbuiltin "is_str" [:any] (fn [_ x] (string? x)))
(defbuiltin "is_int" [:any] (fn [_ x] (integer? x)))
(defbuiltin "is_bool" [:any] (fn [_ x] (boolean? x)))
(defbuiltin "is_list" [:any] (fn [_ x] (vector? x)))
(defbuiltin "glob" [:str]
  (fn [ctx pat] (vfs/glob-paths (:vfs ctx) (compile-or-fail "glob" pat))))

(defn- pathjoin [_ & parts]
  (clojure.string/join "/" (remove empty? parts)))

(defn known?
  "True when `name` is a built-in function."
  [name]
  (or (= name "pathjoin") (contains? @registry name)))

(defn function-names
  "The sorted names of all built-in functions."
  []
  (sort (conj (keys @registry) "pathjoin")))

(defn call
  "Call built-in `fname` with already evaluated `args` in context `ctx` (a map
  with the key `:vfs`).  Performs the arity check, the ascending type checks
  and then runs the function."
  [ctx fname args]
  (let [argc (count args)]
    (if (= fname "pathjoin")
      (do (when-not (<= 1 argc 8)
            (err/fail "E_ARITY" (str "fn pathjoin: expected 1-8, got " argc)))
          (doseq [[i a] (map-indexed vector args)]
            (v/expect-type (str "fn pathjoin argument " (inc i)) "str" string? a))
          (apply pathjoin ctx args))
      (let [{:keys [types] f :fn} (get @registry fname)]
        (when-not (= argc (count types))
          (err/fail "E_ARITY" (str "fn " fname ": expected " (count types) ", got " argc)))
        (doseq [[i t a] (map vector (range) types args)]
          (let [[pred expected] (type-preds t)]
            (v/expect-type (str "fn " fname " argument " (inc i)) expected pred a)))
        (apply f ctx args)))))
