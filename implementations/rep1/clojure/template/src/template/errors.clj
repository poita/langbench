(ns template.errors
  "Error signalling shared by every module.

  All template failures are ordinary `ex-info` exceptions whose data map has a
  `:template/error` key holding one of the kinds in [[kinds]].")

(def kinds
  "The error kinds a render can fail with."
  #{:syntax :filter :undefined :template :type})

(defn fail
  "Throw a template error of `kind` (one of [[kinds]]) with a human message."
  [kind message]
  (throw (ex-info (str (name kind) ": " message) {:template/error kind})))

(defn error-kind
  "The error kind of exception `e`, or nil when it is not a template error."
  [e]
  (:template/error (ex-data e)))
