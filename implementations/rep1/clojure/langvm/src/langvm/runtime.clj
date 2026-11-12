(ns langvm.runtime
  "Run-time value representation shared by the VM and the standard library.

  | Vellum        | JVM representation                                   |
  |---------------|------------------------------------------------------|
  | `Int`         | `java.lang.Long`                                     |
  | `Float`       | `java.lang.Double`                                   |
  | `Bool`        | `java.lang.Boolean`                                  |
  | `Char`        | `java.lang.Integer` holding the scalar value         |
  | `Str`         | [[VStr]] (a String plus its scalar-value length)     |
  | `Unit`        | the singleton [[UNIT]]                               |
  | tuple         | `Object[]`                                           |
  | list          | `java.util.ArrayList`                                |
  | map           | `java.util.LinkedHashMap` (insertion ordered)        |
  | struct / enum | [[Rec]]                                              |
  | closure       | [[Closure]]                                          |"
  (:import (java.util ArrayList LinkedHashMap Map$Entry)))

(set! *warn-on-reflection* true)

(defn- has-surrogates? [^String s]
  (let [n (.length s)]
    (loop [i 0]
      (cond (== i n) false
            (Character/isSurrogate (.charAt s i)) true
            :else (recur (inc i))))))

(deftype VStr [^String s ^long len ^boolean bmp]
  Object
  (equals [_ o] (and (instance? VStr o) (.equals s ^String (.s ^VStr o))))
  (hashCode [_] (.hashCode s))
  (toString [_] s))

(defn vstr
  "Make a Vellum string from a Java String of valid scalar values."
  ^VStr [^String s]
  (if (has-surrogates? s)
    (VStr. s (.codePointCount s 0 (.length s)) false)
    (VStr. s (.length s) true)))

(defn str-of ^String [v] (.s ^VStr v))

(def ^Object UNIT (Object.))

(deftype Rec [^long decl ^long vi ^objects f])

(deftype Closure [^long fn ^objects ups])

(definterface ICaller
  (call [f ^"[Ljava.lang.Object;" args]))

(def empty-array (object-array 0))

(defn panic
  "Abort the program with panic `msg` (a Java String)."
  [^String msg]
  (throw (ex-info msg {:langvm/panic msg})))

(defn panic? [e] (boolean (and (instance? clojure.lang.ExceptionInfo e) (contains? (ex-data e) :langvm/panic))))

;; Option / Result (prelude declarations 0 and 1) -----------------------------

(defn some-of [x] (Rec. 0 0 (object-array [x])))
(def none (Rec. 0 1 empty-array))
(defn ok-of [x] (Rec. 1 0 (object-array [x])))
(defn err-of [x] (Rec. 1 1 (object-array [x])))

;; Head constructor tags --------------------------------------------------------

(defn tag-of
  "Head constructor number of run-time value `v` (see `langvm.types/head-con`)."
  ^long [v]
  (cond
    (instance? Long v) 0
    (instance? Double v) 1
    (instance? Boolean v) 2
    (instance? Integer v) 3
    (instance? VStr v) 4
    (identical? v UNIT) 5
    (instance? ArrayList v) 6
    (instance? LinkedHashMap v) 7
    (instance? Rec v) (+ 8 (.decl ^Rec v))
    :else -1))

;; Structural equality and ordering ---------------------------------------------

(defn veq
  "Structural equality of two values of the same (Eq) type."
  [a b]
  (cond
    (instance? Long a) (== (long a) (long b))
    (instance? Double a) (== (double a) (double b))
    (instance? VStr a) (.equals ^VStr a b)
    (instance? Boolean a) (identical? a b)
    (instance? Integer a) (== (int a) (int b))
    (identical? a UNIT) true
    (instance? Rec a)
    (let [^Rec a a ^Rec b b]
      (and (== (.decl a) (.decl b)) (== (.vi a) (.vi b))
           (let [^objects fa (.f a) ^objects fb (.f b) n (alength fa)]
             (loop [i 0]
               (cond (== i n) true
                     (veq (aget fa i) (aget fb i)) (recur (inc i))
                     :else false)))))
    (instance? ArrayList a)
    (let [^ArrayList a a ^ArrayList b b n (.size a)]
      (and (== n (.size b))
           (loop [i 0]
             (cond (== i n) true
                   (veq (.get a i) (.get b i)) (recur (inc i))
                   :else false))))
    (instance? LinkedHashMap a)
    (let [^LinkedHashMap a a ^LinkedHashMap b b]
      (and (== (.size a) (.size b))
           (every? (fn [^Map$Entry e]
                     (let [k (.getKey e)]
                       (and (.containsKey b k) (veq (.getValue e) (.get b k)))))
                   (.entrySet a))))
    :else
    (let [^objects a a ^objects b b n (alength a)]
      (loop [i 0]
        (cond (== i n) true
              (veq (aget a i) (aget b i)) (recur (inc i))
              :else false)))))

(defn str-compare
  "Compare two strings scalar by scalar: -1, 0 or 1."
  ^long [^VStr a ^VStr b]
  (if (and (.bmp a) (.bmp b))
    (let [c (.compareTo ^String (.s a) ^String (.s b))] (cond (neg? c) -1 (pos? c) 1 :else 0))
    (let [^String sa (.s a) ^String sb (.s b) na (.length sa) nb (.length sb)]
      (loop [i 0 j 0]
        (cond
          (and (>= i na) (>= j nb)) 0
          (>= i na) -1
          (>= j nb) 1
          :else
          (let [ca (.codePointAt sa i) cb (.codePointAt sb j)]
            (cond (< ca cb) -1
                  (> ca cb) 1
                  :else (recur (+ i (Character/charCount ca)) (+ j (Character/charCount cb))))))))))

(defn vlt
  "a < b for Ord values."
  [a b]
  (cond
    (instance? Long a) (< (long a) (long b))
    (instance? Double a) (< (double a) (double b))
    (instance? VStr a) (neg? (str-compare a b))
    (instance? Integer a) (< (int a) (int b))
    :else (and (not (boolean a)) (boolean b))))

(defn vle [a b]
  (cond
    (instance? Long a) (<= (long a) (long b))
    (instance? Double a) (<= (double a) (double b))
    (instance? VStr a) (not (pos? (str-compare a b)))
    (instance? Integer a) (<= (int a) (int b))
    :else (or (not (boolean a)) (boolean b))))
