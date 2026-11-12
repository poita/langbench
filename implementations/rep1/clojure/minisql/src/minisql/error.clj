(ns minisql.error
  "Error signalling shared by every stage of statement processing.

  Anything that makes a statement fail in the way SPEC.md describes (syntax
  errors, unknown tables or columns, bad arity, ...) is raised as an
  `ex-info` whose data carries `::kind`, either `:syntax` or `:semantic`.")

(defn syntax!
  "Throw a syntax error with message `msg`."
  [msg]
  (throw (ex-info msg {::kind :syntax})))

(defn semantic!
  "Throw a semantic (binding / validation) error with message `msg`."
  [msg]
  (throw (ex-info msg {::kind :semantic})))

(defn engine-error?
  "True if `e` was raised by [[syntax!]] or [[semantic!]]."
  [e]
  (and (instance? clojure.lang.ExceptionInfo e)
       (contains? (ex-data e) ::kind)))
