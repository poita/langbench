(ns scheme.printer
  "The *write* and *display* forms of values."
  (:require [scheme.types :as t])
  (:import [scheme.types Pair Sym Closure Primitive]))

(set! *warn-on-reflection* true)

(defn- write-string-literal [^StringBuilder sb ^String s]
  (.append sb \")
  (dotimes [i (.length s)]
    (let [c (.charAt s i)]
      (case c
        \\ (.append sb "\\\\")
        \" (.append sb "\\\"")
        \newline (.append sb "\\n")
        \tab (.append sb "\\t")
        (.append sb c))))
  (.append sb \"))

(defn print-to
  "Append the printed form of `x` to `sb`. With `display?` true strings are
  written raw; otherwise quoted and escaped."
  [^StringBuilder sb x display?]
  (cond
    (instance? String x) (if display? (.append sb ^String x) (write-string-literal sb x))
    (instance? Sym x) (.append sb (.name ^Sym x))
    (instance? Boolean x) (.append sb (if x "#t" "#f"))
    (instance? Pair x)
    (do (.append sb \()
        (loop [p x first? true]
          (cond
            (instance? Pair p)
            (do (when-not first? (.append sb \space))
                (print-to sb (.car ^Pair p) display?)
                (recur (.cdr ^Pair p) false))
            (t/nil-obj? p) nil
            :else (do (.append sb " . ") (print-to sb p display?))))
        (.append sb \)))
    (t/nil-obj? x) (.append sb "()")
    (t/void? x) (.append sb "#<void>")
    (or (instance? Closure x) (instance? Primitive x)) (.append sb "#<procedure>")
    :else (.append sb (str x)))   ; integers: Long / Bignum
  sb)

(defn write-str
  "The *write* form of `x` as a string."
  ^String [x]
  (.toString ^StringBuilder (print-to (StringBuilder.) x false)))

(defn display-str
  "The *display* form of `x` as a string."
  ^String [x]
  (if (instance? String x)
    x
    (.toString ^StringBuilder (print-to (StringBuilder.) x true))))
