(ns scheme.runtime
  "Procedure application and the trampoline.

  Evaluating a node in tail position yields a `TailCall` instead of running
  the call; `call` loops until a real value comes back, so tail loops use
  constant host stack. Non-tail calls nest host frames."
  (:require [scheme.types :as t])
  (:import [scheme.types Closure Primitive TailCall Node Frame]))

(set! *warn-on-reflection* true)

(defn- bind-args
  "The call frame for applying closure `c` to `args` (a fresh array)."
  ^Frame [^Closure c ^objects args]
  (let [n (alength args)
        nreq (.nreq c)]
    (if (.variadic c)
      (do
        (when (< n nreq) (t/arity-error!))
        (let [vals (object-array (inc nreq))]
          (System/arraycopy args 0 vals 0 nreq)
          (aset vals nreq (t/array->list args nreq))
          (t/make-frame (.params c) vals (.env c))))
      (do
        (when-not (== n nreq) (t/arity-error!))
        (t/make-frame (.params c) args (.env c))))))

(defn call-primitive
  "Apply primitive `p` to `args`, checking arity first."
  [^Primitive p ^objects args]
  (let [n (alength args)
        f ^clojure.lang.IFn (.f p)]
    (when (or (< n (.min-args p))
              (and (>= (.max-args p) 0) (> n (.max-args p))))
      (t/arity-error!))
    (case n
      0 (.invoke f)
      1 (.invoke f (aget args 0))
      2 (.invoke f (aget args 0) (aget args 1))
      3 (.invoke f (aget args 0) (aget args 1) (aget args 2))
      (.applyTo f (seq args)))))

(defn apply-once
  "Apply `f` to `args` once. The result may be a `TailCall`."
  [f ^objects args]
  (cond
    (instance? Closure f) (.ev ^Node (.body ^Closure f) (bind-args f args))
    (instance? Primitive f) (call-primitive f args)
    :else (t/type-error!)))

(defn call
  "Apply `f` to `args` and run any tail calls to completion."
  [f ^objects args]
  (loop [r (apply-once f args)]
    (if (instance? TailCall r)
      (recur (apply-once (.f ^TailCall r) (.args ^TailCall r)))
      r)))

(defn force-value
  "Run `r` to completion if it is a `TailCall`."
  [r]
  (if (instance? TailCall r)
    (call (.f ^TailCall r) (.args ^TailCall r))
    r))
