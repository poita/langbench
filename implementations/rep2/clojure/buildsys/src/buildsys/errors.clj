(ns buildsys.errors
  "Error plumbing shared by every module.

  Kiln reports exactly one error per failed build, rendered as
  `KIND detail`.  Such errors are thrown as `ex-info` values whose data
  carries `::kiln-error`; `kiln-error?` recognises them and `render` turns
  them into the text that appears on a log line.

  Lexical and grammatical failures use a separate, lighter-weight signal
  (`parse-fail!`) that carries no position: the layer that knows which logical
  line was being processed attaches the line number (see `with-line`)."
  (:import (clojure.lang ExceptionInfo)))

(defn kiln-error
  "Builds (without throwing) a Kiln error of `kind` (e.g. \"E_ARG\") with an
  optional `detail` string."
  [kind detail]
  (ex-info (if detail (str kind " " detail) kind)
           {::kiln-error true :kind kind :detail detail}))

(defn fail!
  "Throws a Kiln error of `kind`, with an optional `detail`."
  ([kind] (throw (kiln-error kind nil)))
  ([kind detail] (throw (kiln-error kind detail))))

(defn kiln-error?
  "True when `ex` is a Kiln error created by `kiln-error` / `fail!`."
  [ex]
  (and (instance? ExceptionInfo ex) (boolean (::kiln-error (ex-data ex)))))

(defn render
  "The `KIND detail` text of a Kiln error (just `KIND` when it has no detail)."
  [ex]
  (ex-message ex))

(defn parse-fail!
  "Signals a lexical or grammatical error at an as yet unknown line."
  []
  (throw (ex-info "parse error" {::parse true})))

(defn parse-error?
  "True when `ex` was raised by `parse-fail!`."
  [ex]
  (and (instance? ExceptionInfo ex) (boolean (::parse (ex-data ex)))))

(defn parse-error-line
  "The line attached to a parse error by `with-line`, or nil."
  [ex]
  (::line (ex-data ex)))

(defn with-line
  "Returns the parse error `ex` tagged with logical line number `line`, unless
  it already carries one (the earliest attribution wins)."
  [ex line]
  (if (parse-error-line ex)
    ex
    (ex-info "parse error" {::parse true ::line line})))
