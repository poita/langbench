(ns linalg.error
  "The error taxonomy of the library.

  Every failure that is the caller's fault (as opposed to a bug) is reported by
  throwing an `ex-info` whose data map carries the key `:linalg/error` with one
  of the codes in [[codes]]."
  )

(def codes
  "The five error codes a linear algebra operation can fail with."
  #{:dimension-mismatch :not-square :not-symmetric :not-positive-definite :singular})

(defn fail!
  "Throws a linalg error with the given `code` (a keyword from [[codes]])."
  [code]
  (throw (ex-info (name code) {:linalg/error code})))

(defn error-code
  "Returns the linalg error code carried by exception `e`, or nil when `e` is
  not a linalg error."
  [e]
  (:linalg/error (ex-data e)))

(defn code->string
  "The wire spelling of an error code: `:not-positive-definite` becomes
  \"not_positive_definite\"."
  [code]
  (.replace (name code) \- \_))
