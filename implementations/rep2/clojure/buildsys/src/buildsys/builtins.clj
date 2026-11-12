(ns buildsys.builtins
  "The 39 built-in KBL functions.

  `table` maps a function name to a descriptor
    {:arity n | [lo hi]   :types [type-token ...]   :f (fn [vfs args] ...)}
  and `call` implements the exact call protocol of the specification: arity,
  then argument types in ascending order, then the function itself."
  (:require [buildsys.errors :as e]
            [buildsys.glob :as glob]
            [buildsys.value :as v]
            [buildsys.vfs :as vfs]
            [clojure.string :as str]))

(set! *warn-on-reflection* true)

;; ----------------------------------------------------------------- type tokens

(def ^:private type-checks
  {:str      ["str" string?]
   :int      ["int" integer?]
   :list     ["list" vector?]
   :str|list ["str|list" #(or (string? %) (vector? %))]
   :str|int  ["str|int" #(or (string? %) (integer? %))]
   :scalar   ["str|int|bool" #(or (string? %) (integer? %) (boolean? %))]})

(defn- check-type! [fname i token arg]
  (when-not (= token :any)
    (let [[expected ok?] (type-checks token)]
      (when-not (ok? arg)
        (v/type-error! (str "fn " fname " argument " (inc i)) expected arg)))))

;; ----------------------------------------------------------------- strings

(defn- trim-ws ^String [^String s]
  (let [ws? (fn [c] (or (= c \space) (= c \tab) (= c \newline) (= c \return)))
        n (.length s)
        a (loop [i 0] (if (and (< i n) (ws? (.charAt s i))) (recur (inc i)) i))
        b (loop [j n] (if (and (> j a) (ws? (.charAt s (dec j)))) (recur (dec j)) j))]
    (subs s a b)))

(defn- ascii-case ^String [^String s upper?]
  (let [n (.length s) sb (StringBuilder. n)]
    (dotimes [i n]
      (let [c (.charAt s i)]
        (.append sb (cond (and upper? (<= (int \a) (int c) (int \z))) (char (- (int c) 32))
                          (and (not upper?) (<= (int \A) (int c) (int \Z))) (char (+ (int c) 32))
                          :else c))))
    (str sb)))

(defn replace-all
  "Left-to-right, non-overlapping replacement of `from` (non-empty) by `to`."
  ^String [^String s ^String from ^String to]
  (.replace s from to))

(defn- clamp ^long [^long x ^long lo ^long hi] (max lo (min hi x)))

(defn- window
  "Shared clamping of `substr` / `slice`: returns [start end)."
  [^long n ^long start ^long cnt]
  (let [start (clamp (if (neg? start) (+ n start) start) 0 n)
        cnt (clamp cnt 0 (- n start))]
    [start (+ start cnt)]))

(defn- split-str [^String s ^String sep]
  (let [m (.length sep)]
    (loop [from 0 acc []]
      (let [i (.indexOf s sep (int from))]
        (if (neg? i)
          (conj acc (subs s from))
          (recur (+ i m) (conj acc (subs s from i))))))))

(defn- parse-int-str [^String s]
  (let [n (.length s)
        start (if (and (pos? n) (= \- (.charAt s 0))) 1 0)]
    (when (and (< start n)
               (every? #(<= (int \0) (int %) (int \9)) (subs s start)))
      (let [b (java.math.BigInteger. s)]
        (when (<= (.bitLength b) 63) (.longValue b))))))

(defn- basename* ^String [^String p]
  (let [i (.lastIndexOf p "/")] (if (neg? i) p (subs p (inc i)))))

(defn- dot-index
  "Index of the last `.` of `b` that is not at index 0, or -1."
  ^long [^String b]
  (let [i (.lastIndexOf b ".")] (if (pos? i) i -1)))

(defn- map-pattern [^String pat ^String element]
  (let [n (.length pat) sb (StringBuilder.)]
    (loop [i 0]
      (when (< i n)
        (let [c (.charAt pat i)]
          (if (= c \%)
            (if (and (< (inc i) n) (= \% (.charAt pat (inc i))))
              (do (.append sb \%) (recur (+ i 2)))
              (do (.append sb element) (recur (inc i))))
            (do (.append sb c) (recur (inc i)))))))
    (str sb)))

;; ------------------------------------------------------------------- lists

(defn- compile-glob! [fname pat]
  (or (glob/compile-pattern pat)
      (e/fail! "E_ARG" (str "fn " fname ": bad pattern"))))

(defn- filter-list [fname keep-match? l pat]
  (let [cp (compile-glob! fname pat)]
    (loop [i 0 acc (transient [])]
      (if (< i (count l))
        (let [x (nth l i)]
          (when-not (string? x)
            (v/type-error! (str "fn " fname " element " i) "str" x))
          (recur (inc i) (if (= keep-match? (glob/matches? cp x)) (conj! acc x) acc)))
        (persistent! acc)))))

(defn- glob-workspace [vfs pat]
  (let [cp (compile-glob! "glob" pat)
        prefix (glob/literal-prefix pat)]
    (into []
          (filter (fn [^String p]
                    (and (not (vfs/generated-path? p))
                         (not= p vfs/state-path)
                         (glob/matches? cp p))))
          (vfs/paths-with-prefix vfs prefix))))

;; ------------------------------------------------------------------- table

(defn- fn-entry [arity types f] {:arity arity :types types :f f})

(def table
  "name -> {:arity :types :f}.  `:f` is called as `(f vfs args)`."
  {"len"        (fn-entry 1 [:str|list] (fn [_ [x]] (long (count x))))
   "count"      (fn-entry 1 [:list] (fn [_ [l]] (long (count l))))
   "upper"      (fn-entry 1 [:str] (fn [_ [s]] (ascii-case s true)))
   "lower"      (fn-entry 1 [:str] (fn [_ [s]] (ascii-case s false)))
   "trim"       (fn-entry 1 [:str] (fn [_ [s]] (trim-ws s)))
   "replace"    (fn-entry 3 [:str :str :str]
                          (fn [_ [s from to]]
                            (when (empty? from) (e/fail! "E_ARG" "fn replace: empty pattern"))
                            (replace-all s from to)))
   "starts_with" (fn-entry 2 [:str :str] (fn [_ [s p]] (.startsWith ^String s ^String p)))
   "ends_with"  (fn-entry 2 [:str :str] (fn [_ [s p]] (.endsWith ^String s ^String p)))
   "contains"   (fn-entry 2 [:str :str] (fn [_ [s p]] (<= 0 (.indexOf ^String s ^String p))))
   "substr"     (fn-entry 3 [:str :int :int]
                          (fn [_ [s start cnt]]
                            (let [[a b] (window (count s) start cnt)] (subs s a b))))
   "split"      (fn-entry 2 [:str :str]
                          (fn [_ [s sep]]
                            (when (empty? sep) (e/fail! "E_ARG" "fn split: empty separator"))
                            (split-str s sep)))
   "join"       (fn-entry 2 [:list :str]
                          (fn [_ [l sep]]
                            (let [sb (StringBuilder.)]
                              (dotimes [i (count l)]
                                (let [x (nth l i)]
                                  (when-not (or (string? x) (integer? x))
                                    (v/type-error! (str "fn join element " i) "str|int" x))
                                  (when (pos? i) (.append sb ^String sep))
                                  (.append sb ^String (v/->text x))))
                              (str sb))))
   "str"        (fn-entry 1 [:scalar] (fn [_ [x]] (v/->text x)))
   "int"        (fn-entry 1 [:str|int]
                          (fn [_ [x]]
                            (if (integer? x)
                              x
                              (or (parse-int-str x) (e/fail! "E_ARG" "fn int: bad integer")))))
   "dirname"    (fn-entry 1 [:str] (fn [_ [^String p]]
                                     (let [i (.lastIndexOf p "/")] (if (neg? i) "" (subs p 0 i)))))
   "basename"   (fn-entry 1 [:str] (fn [_ [p]] (basename* p)))
   "stem"       (fn-entry 1 [:str] (fn [_ [p]]
                                     (let [b (basename* p) i (dot-index b)]
                                       (if (neg? i) b (subs b 0 i)))))
   "ext"        (fn-entry 1 [:str] (fn [_ [p]]
                                     (let [b (basename* p) i (dot-index b)]
                                       (if (neg? i) "" (subs b i)))))
   "pathjoin"   (fn-entry [1 8] (vec (repeat 8 :str))
                          (fn [_ args] (str/join "/" (remove empty? args))))
   "map"        (fn-entry 2 [:list :str]
                          (fn [_ [l pat]]
                            (vec (map-indexed
                                  (fn [i x]
                                    (when-not (string? x)
                                      (v/type-error! (str "fn map element " i) "str" x))
                                    (map-pattern pat x))
                                  l))))
   "filter"     (fn-entry 2 [:list :str] (fn [_ [l pat]] (filter-list "filter" true l pat)))
   "reject"     (fn-entry 2 [:list :str] (fn [_ [l pat]] (filter-list "reject" false l pat)))
   "sort"       (fn-entry 1 [:list] (fn [_ [l]] (vec (sort v/compare-values l))))
   "uniq"       (fn-entry 1 [:list]
                          (fn [_ [l]]
                            (loop [xs (seq l) seen #{} acc (transient [])]
                              (if xs
                                (let [x (first xs)]
                                  (if (seen x)
                                    (recur (next xs) seen acc)
                                    (recur (next xs) (conj seen x) (conj! acc x))))
                                (persistent! acc)))))
   "reverse"    (fn-entry 1 [:list] (fn [_ [l]] (vec (rseq l))))
   "first"      (fn-entry 1 [:list] (fn [_ [l]]
                                      (if (empty? l) (e/fail! "E_ARG" "fn first: empty list") (nth l 0))))
   "last"       (fn-entry 1 [:list] (fn [_ [l]]
                                      (if (empty? l) (e/fail! "E_ARG" "fn last: empty list") (peek l))))
   "slice"      (fn-entry 3 [:list :int :int]
                          (fn [_ [l start cnt]]
                            (let [[a b] (window (count l) start cnt)] (subvec l a b))))
   "has"        (fn-entry 2 [:list :any] (fn [_ [l x]] (boolean (some #(= x %) l))))
   "indexof"    (fn-entry 2 [:list :any]
                          (fn [_ [l x]]
                            (or (first (keep-indexed (fn [i y] (when (= x y) (long i))) l)) -1)))
   "range"      (fn-entry 1 [:int]
                          (fn [_ [n]]
                            (when (neg? (long n)) (e/fail! "E_ARG" "fn range: negative"))
                            (vec (range (long n)))))
   "sum"        (fn-entry 1 [:list]
                          (fn [_ [l]]
                            (loop [i 0 acc 0]
                              (if (< i (count l))
                                (let [x (nth l i)]
                                  (when-not (integer? x)
                                    (v/type-error! (str "fn sum element " i) "int" x))
                                  (recur (inc i) (unchecked-add (long acc) (long x))))
                                acc))))
   "flatten"    (fn-entry 1 [:list]
                          (fn [_ [l]]
                            (reduce (fn [acc x] (if (vector? x) (into acc x) (conj acc x))) [] l)))
   "zip"        (fn-entry 2 [:list :list]
                          (fn [_ [a b]] (mapv vector a b)))
   "is_str"     (fn-entry 1 [:any] (fn [_ [x]] (string? x)))
   "is_int"     (fn-entry 1 [:any] (fn [_ [x]] (integer? x)))
   "is_bool"    (fn-entry 1 [:any] (fn [_ [x]] (boolean? x)))
   "is_list"    (fn-entry 1 [:any] (fn [_ [x]] (vector? x)))
   "glob"       (fn-entry 1 [:str] (fn [vfs [pat]] (glob-workspace vfs pat)))})

(defn known? "True when `name` is a built-in function." [name] (contains? table name))

(defn call
  "Applies built-in `name` to already evaluated `args` against workspace `vfs`,
  checking arity then argument types in order, as the specification requires.
  The caller is responsible for the unknown-name check (which precedes
  argument evaluation)."
  [vfs name args]
  (let [{:keys [arity types f]} (table name)
        m (count args)
        [lo hi] (if (vector? arity) arity [arity arity])]
    (when-not (<= lo m hi)
      (e/fail! "E_ARITY" (str "fn " name ": expected "
                              (if (vector? arity) (str lo "-" hi) lo) ", got " m)))
    (dotimes [i m] (check-type! name i (nth types i) (nth args i)))
    (f vfs args)))
