(ns scheme.primitives
  "The initial global environment: every primitive procedure of SPEC.md."
  (:require [scheme.number :as num]
            [scheme.printer :as printer]
            [scheme.types :as t])
  (:import [java.io Writer]
           [java.util HashMap]
           [scheme.types Closure Pair Primitive Sym TailCall]))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Equivalence

(defn eq-values?
  "Scheme `eq?`: integers by value; otherwise object identity (symbols are
  interned, `()` and void are singletons)."
  [a b]
  (cond
    (identical? a b) true
    (and (num/integer? a) (num/integer? b)) (zero? (num/compare-int a b))
    (and (instance? Boolean a) (instance? Boolean b)) (= a b)
    :else false))

(defn equal-values?
  "Scheme `equal?`: structural on pairs and strings, `eq?` otherwise.
  Iterates along cdrs, so long lists do not consume stack."
  [a b]
  (loop [a a b b]
    (cond
      (and (instance? Pair a) (instance? Pair b))
      (if (equal-values? (.car ^Pair a) (.car ^Pair b))
        (recur (.cdr ^Pair a) (.cdr ^Pair b))
        false)
      (and (instance? String a) (instance? String b)) (.equals ^String a b)
      :else (eq-values? a b))))

;; ---------------------------------------------------------------------------
;; Argument checking

(defn- int! [x]
  (if (num/integer? x) x (t/type-error!)))

(defn- string! ^String [x]
  (if (instance? String x) x (t/type-error!)))

(defn- check-all! [xs] (run! int! xs))

(defn- comparison
  "A variadic numeric comparison: `test` receives -1/0/1 for each adjacent
  pair, and every argument is type-checked before any pair is compared."
  [test]
  (fn
    ([a b] (int! a) (int! b) (boolean (test (num/compare-int a b))))
    ([a b & more]
     (let [all (list* a b more)]
       (check-all! all)
       (every? true? (map (fn [x y] (boolean (test (num/compare-int x y))))
                          all (rest all)))))))

(def ^:private plus
  (fn
    ([] 0)
    ([a] (int! a))
    ([a b] (num/add (int! a) (int! b)))
    ([a b & more] (let [all (list* a b more)]
                    (check-all! all)
                    (reduce num/add all)))))

(def ^:private times
  (fn
    ([] 1)
    ([a] (int! a))
    ([a b] (num/mul (int! a) (int! b)))
    ([a b & more] (let [all (list* a b more)]
                    (check-all! all)
                    (reduce num/mul all)))))

(def ^:private minus
  (fn
    ([a] (num/negate (int! a)))
    ([a b] (num/sub (int! a) (int! b)))
    ([a b & more] (let [all (list* a b more)]
                    (check-all! all)
                    (reduce num/sub all)))))

(defn- division [op]
  (fn [a b]
    (int! a) (int! b)
    (if (num/zero-int? b)
      (throw (t/scheme-error :division-by-zero))
      (op a b))))

(defn- apply-prim
  "`(apply f a ... lst)`: a tail call of `f`."
  [f & args]
  (let [arr (object-array args)
        n (alength arr)
        spread (t/list->vector (aget arr (dec n)))]
    (when (nil? spread) (t/type-error!))
    (TailCall. f (object-array (concat (take (dec n) arr) spread)))))

;; ---------------------------------------------------------------------------
;; The table

(defn- primitive-table
  "Vector of [name min-args max-args fn] (max-args -1 means variadic).
  `out` is the Writer that `display` and `newline` write to."
  [^Writer out]
  [["+" 0 -1 plus]
   ["*" 0 -1 times]
   ["-" 1 -1 minus]
   ["quotient" 2 2 (division num/quot)]
   ["remainder" 2 2 (division num/rem)]
   ["=" 2 -1 (comparison zero?)]
   ["<" 2 -1 (comparison neg?)]
   [">" 2 -1 (comparison pos?)]
   ["<=" 2 -1 (comparison (complement pos?))]
   [">=" 2 -1 (comparison (complement neg?))]

   ["cons" 2 2 (fn [a d] (Pair. a d))]
   ["car" 1 1 (fn [p] (if (instance? Pair p) (.car ^Pair p) (t/type-error!)))]
   ["cdr" 1 1 (fn [p] (if (instance? Pair p) (.cdr ^Pair p) (t/type-error!)))]
   ["list" 0 -1 (fn [& xs] (t/vector->list xs))]
   ["null?" 1 1 (fn [x] (t/nil-obj? x))]
   ["pair?" 1 1 (fn [x] (instance? Pair x))]

   ["not" 1 1 (fn [x] (false? x))]
   ["number?" 1 1 (fn [x] (num/integer? x))]
   ["boolean?" 1 1 (fn [x] (instance? Boolean x))]
   ["string?" 1 1 (fn [x] (instance? String x))]
   ["symbol?" 1 1 (fn [x] (instance? Sym x))]
   ["procedure?" 1 1 (fn [x] (t/procedure? x))]
   ["eq?" 2 2 eq-values?]
   ["equal?" 2 2 equal-values?]

   ["apply" 2 -1 apply-prim]
   ["error" 0 -1 (fn [& _] (throw (t/scheme-error :user-error)))]

   ["string-append" 0 -1 (fn [& ss]
                           (let [sb (StringBuilder.)]
                             (run! string! ss)
                             (run! #(.append sb ^String %) ss)
                             (.toString sb)))]
   ["string-length" 1 1 (fn [s] (long (.length (string! s))))]
   ["number->string" 1 1 (fn [n] (num/->string (int! n)))]
   ["symbol->string" 1 1 (fn [s] (if (instance? Sym s) (.name ^Sym s) (t/type-error!)))]

   ["display" 1 1 (fn [x] (.write out (printer/display-str x)) t/VOID)]
   ["newline" 0 0 (fn [] (.write out "\n") t/VOID)]])

(defn install!
  "Bind every primitive in the global table `g`, with `display`/`newline`
  writing to `out`."
  [^HashMap g ^Writer out]
  (doseq [[name lo hi f] (primitive-table out)]
    (.put g (t/intern-sym name) (Primitive. name lo hi f)))
  g)
