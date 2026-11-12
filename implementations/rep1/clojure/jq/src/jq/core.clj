(ns jq.core
  "Public API of the jq-subset interpreter.

      (require '[jq.core :as jq])

      (jq/query \".a | map(. * 2)\" {\"a\" [1 2 3]})   ;=> [[2.0 4.0 6.0]]
      (jq/query-string \".[] | select(. > 1)\" \"[1,2,3]\") ;=> [\"2\" \"3\"]

  Values are jq values (see [[jq.value]]): `nil`, booleans, doubles, strings,
  vectors and [[jq.value/JObj]] objects. [[jq.value/from-clj]] and
  [[jq.value/to-clj]] convert to and from ordinary Clojure data, and
  [[jq.json/parse]] / [[jq.json/stringify]] to and from JSON text."
  (:refer-clojure :exclude [compile])
  (:require [jq.parser :as parser]
            [jq.interp :as interp]
            [jq.json :as json]
            [jq.value :as v]))

(defn compile
  "Compiles filter source text into a reusable filter. Throws `ex-info` with
  `{:type :jq/parse-error}` if the text is not a valid filter of the subset."
  [^String source]
  (interp/compile-ast (parser/parse source)))

(defn run-each
  "Runs the compiled `filter` on the jq value `input`, calling `(emit value)`
  for each output as soon as it is produced. A jq runtime error that is not
  caught by the filter is thrown (test it with [[error?]]); outputs produced
  before it have already been emitted. `vars` optionally maps variable names
  (without `$`) to jq values."
  ([filter input emit] (run-each filter input emit {}))
  ([filter input emit vars]
   (filter vars input emit)
   nil))

(defn run
  "Runs the compiled `filter` on `input` and returns a vector of all outputs.
  If evaluation raises an error, throws an `ex-info` whose data holds
  `:results` (the outputs produced before the error) and `:value` (the error
  value); [[error?]] is true for it."
  ([filter input] (run filter input {}))
  ([filter input vars]
   (let [out (java.util.ArrayList.)]
     (try
       (run-each filter input #(.add out %) vars)
       (catch clojure.lang.ExceptionInfo e
         (if (v/jq-error? e)
           (throw (ex-info (ex-message e)
                           {:type :jq/runtime-error
                            :value (v/error-value e)
                            :results (vec out)}
                           e))
           (throw e))))
     (vec out))))

(defn query
  "Compiles `source` and runs it on the jq value `input`; returns a vector of
  outputs. Shorthand for `(run (compile source) input)`."
  [source input]
  (run (compile source) input))

(defn query-string
  "Like [[query]] but takes the input as JSON text and returns the outputs as
  a vector of compact JSON strings."
  [source ^String json-text]
  (mapv json/stringify (query source (json/parse json-text))))

(defn error?
  "True if `e` is the exception [[run]] throws for a jq runtime error."
  [e]
  (and (instance? clojure.lang.ExceptionInfo e)
       (= :jq/runtime-error (:type (ex-data e)))))
