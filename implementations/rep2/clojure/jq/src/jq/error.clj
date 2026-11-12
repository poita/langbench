(ns jq.error
  "Errors raised while evaluating a filter.

  A jq runtime error is an `ExceptionInfo` whose data carries the raised value
  under `::value`. `try` (the `?` operator) catches exactly these and lets
  every other exception (including internal bugs) through."
  (:import (clojure.lang ExceptionInfo)))

(defn jq-error
  "Returns (does not throw) a jq runtime error carrying the value `v`."
  [v]
  (ex-info "jq error" {::error true ::value v}))

(defn jq-error?
  "True when `e` is a jq runtime error (as built by [[jq-error]])."
  [e]
  (and (instance? ExceptionInfo e)
       (boolean (::error (ex-data e)))))

(defn error-value
  "The value carried by the jq error `e`."
  [e]
  (::value (ex-data e)))

(defn raise
  "Throws a jq runtime error carrying `v`."
  [v]
  (throw (jq-error v)))

(defn passthrough
  "Wraps the jq error `e` so that it travels through the `try` identified by
  `token` unharmed. Used by the evaluator to distinguish errors raised inside
  a `try` body from errors raised downstream of it."
  [token e]
  (ex-info "jq passthrough" {::passthrough token ::inner e}))

(defn passthrough-of?
  "True when `e` is a passthrough wrapper created for `token`."
  [e token]
  (and (instance? ExceptionInfo e)
       (identical? token (::passthrough (ex-data e)))))

(defn unwrap-passthrough
  "The jq error wrapped inside a passthrough exception."
  [e]
  (::inner (ex-data e)))
