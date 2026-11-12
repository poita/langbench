(ns typeinfer.printer
  "Rendering types as strings.

  Type variables are named in order of first appearance, reading left to
  right: `'a`, `'b`, ..., `'z`, `'a1`, `'b1`, ... Parentheses appear only
  where needed: a function type on the left of `->` or as a tuple component
  or list element, and a tuple type as a tuple component or list element."
  (:require [typeinfer.types :as t])
  (:import (java.util IdentityHashMap)))

(set! *warn-on-reflection* true)

(defn var-name
  "The name of the `i`-th (0-based) type variable: `'a` .. `'z`, `'a1` ..."
  [^long i]
  (let [q (quot i 26)]
    (str "'" (char (+ 97 (rem i 26))) (when (pos? q) q))))

(defn- emit! [^StringBuilder sb ^IdentityHashMap names ^long prec ty]
  (let [ty (t/prune ty)]
    (if (t/tvar? ty)
      (let [nm (or (.get names ty)
                   (let [nm (var-name (.size names))]
                     (.put names ty nm)
                     nm))]
        (.append sb ^String nm))
      (let [xs (t/args ty)]
        (case (t/tag ty)
          :int  (.append sb "int")
          :bool (.append sb "bool")
          :unit (.append sb "unit")
          :list (do (emit! sb names 2 (xs 0))
                    (.append sb " list"))
          :arrow (let [paren? (>= prec 1)]
                   (when paren? (.append sb \())
                   (emit! sb names 1 (xs 0))
                   (.append sb " -> ")
                   (emit! sb names 0 (xs 1))
                   (when paren? (.append sb \))))
          :tuple (let [paren? (>= prec 2)]
                   (when paren? (.append sb \())
                   (dotimes [i (count xs)]
                     (when (pos? i) (.append sb " * "))
                     (emit! sb names 2 (xs i)))
                   (when paren? (.append sb \)))))))))

(defn type->string
  "Render the type `ty` with variables named by order of first appearance."
  [ty]
  (let [sb (StringBuilder.)]
    (emit! sb (IdentityHashMap.) 0 ty)
    (.toString sb)))
