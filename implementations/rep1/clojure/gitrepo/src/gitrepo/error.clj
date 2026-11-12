(ns gitrepo.error
  "Failures. Everything that can go wrong while reading a repository is
  reported by throwing an `ex-info` built here, so callers can tell a gitrepo
  failure (`failure?`) from a programming error.")

(defn fail
  "Throws a gitrepo failure. `kind` is one of `:missing` (object not found),
  `:damaged` (object present but unreadable), `:bad-rev` (revision does not
  resolve), `:bad-arg` (malformed command or argument)."
  ([kind msg] (fail kind msg {}))
  ([kind msg data]
   (throw (ex-info msg (assoc data :gitrepo/failure kind)))))

(defn failure?
  "True when `e` was thrown by `fail`."
  [e]
  (boolean (and (instance? clojure.lang.ExceptionInfo e)
                (:gitrepo/failure (ex-data e)))))

(defn kind
  "The failure kind of `e`, or nil."
  [e]
  (when (instance? clojure.lang.ExceptionInfo e)
    (:gitrepo/failure (ex-data e))))
