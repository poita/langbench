(ns buildsys.error
  "Kiln build errors.

  A build fails with exactly one error, identified by a kind such as
  `\"E_PARSE\"` and an optional detail string.  Errors are thrown as
  `ex-info` values tagged with `::kiln-error` so that the build driver can
  tell them apart from genuine bugs (which propagate unchanged).")

(defn fail
  "Throw a Kiln error of `kind` with an optional `detail` string."
  ([kind] (fail kind nil))
  ([kind detail]
   (throw (ex-info (if detail (str kind " " detail) kind)
                   {::kiln-error true :kind kind :detail detail}))))

(defn kiln-error?
  "True when `e` is a Throwable produced by [[fail]]."
  [e]
  (boolean (and (instance? clojure.lang.ExceptionInfo e)
                (::kiln-error (ex-data e)))))

(defn render
  "Render a Kiln error exception as `KIND detail` (or just `KIND`)."
  [e]
  (let [{:keys [kind detail]} (ex-data e)]
    (if detail (str kind " " detail) kind)))

(defn parse-error
  "Throw an `E_PARSE` error for `line` of build file `file`."
  [file line]
  (fail "E_PARSE" (str file ":" line)))
