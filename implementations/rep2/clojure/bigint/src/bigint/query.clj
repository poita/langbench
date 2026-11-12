(ns bigint.query
  "Evaluation of one textual query of the form `<a> <op> <b>`.

  Operators: `+ - * / % ^ cmp`. See SPEC.md for the full contract."
  (:require [bigint.core :as bi])
  (:import (clojure.lang ExceptionInfo)))

(set! *warn-on-reflection* true)

(def error-output
  "What is printed for a query that has no defined result."
  "error")

(defn parse-query
  "Split `line` into [a op b] strings. Throws ex-info (`:type ::malformed`)
  unless the line has exactly three single-space separated tokens."
  [^String line]
  (let [i (.indexOf line " ")
        j (if (neg? i) -1 (.indexOf line " " (int (inc i))))]
    (when (or (neg? i) (neg? j) (>= (.indexOf line " " (int (inc j))) 0))
      (throw (ex-info "Malformed query" {:type ::malformed :line line})))
    [(subs line 0 i) (subs line (inc i) j) (subs line (inc j))]))

(defn- apply-op
  "Result of `op` on Ints a and b, as a string."
  ^String [^String op a b]
  (case op
    "+"   (bi/->string (bi/add a b))
    "-"   (bi/->string (bi/sub a b))
    "*"   (bi/->string (bi/mul a b))
    "/"   (bi/->string (bi/quot a b))
    "%"   (bi/->string (bi/rem a b))
    "^"   (bi/->string (bi/pow a b))
    "cmp" (Long/toString (bi/cmp a b))
    (throw (ex-info "Unknown operator" {:type ::unknown-operator :op op}))))

(defn evaluate
  "Evaluate one query line and return the output line (without newline):
  the canonical result, `-1`/`0`/`1` for `cmp`, or `error` for division by
  zero and negative exponents."
  ^String [^String line]
  (let [[a op b] (parse-query line)]
    (try
      (apply-op op (bi/parse a) (bi/parse b))
      (catch ExceptionInfo e
        (if (#{::bi/division-by-zero ::bi/negative-exponent}
             (:type (ex-data e)))
          error-output
          (throw e))))))
