(ns jq.core
  "Public API of the jq library: parse a filter, run it on JSON values.

  ```clojure
  (require '[jq.core :as jq])

  (jq/query \".a | map(. * 2)\" \"{\\\"a\\\":[1,2,3]}\")
  ;=> [\"[2,4,6]\"]

  (def f (jq/compile-filter \".[] | select(. > 1)\"))
  (jq/run f (jq/parse-json \"[1,2,3]\"))
  ;=> [2.0 3.0]
  ```

  Values use the representation described in [[jq.value]]."
  (:require [jq.error :as err]
            [jq.eval :as eval]
            [jq.json :as json]
            [jq.parser :as parser]
            [jq.value :as v]))

(set! *warn-on-reflection* true)

(defn compile-filter
  "Parses and compiles the filter text `src`. Returns a function
  `(f input emit)` that calls `(emit output)` for every output of the filter on
  `input`, in order. Throws `ex-info` for syntax errors, unknown functions and
  undefined variables."
  [^String src]
  (let [closure (eval/compile-node (parser/parse src) #{})]
    (fn [input emit] (closure {} input emit))))

(defn run
  "Runs the compiled filter `f` on `input` and returns a vector of all its
  outputs. Throws if evaluation raises a jq error (the outputs produced before
  it are in the `:outputs` key of the exception data)."
  [f input]
  (let [out (java.util.ArrayList.)]
    (try
      (f input (fn [x] (.add out x)))
      (catch clojure.lang.ExceptionInfo e
        (if (err/jq-error? e)
          (throw (ex-info "jq error" {:jq.core/error (err/error-value e)
                                      :outputs (vec out)} e))
          (throw e))))
    (vec out)))

(defn error?
  "True when `e` is a jq runtime error thrown while running a filter."
  [e]
  (or (err/jq-error? e)
      (and (instance? clojure.lang.ExceptionInfo e)
           (contains? (ex-data e) :jq.core/error))))

(defn parse-json
  "Parses JSON text into a jq value."
  [s]
  (json/parse s))

(defn write-json
  "The compact JSON text of a jq value."
  [x]
  (json/stringify x))

(defn query
  "Convenience: runs the filter text `filter-src` on the JSON text `json-src`
  and returns the vector of results as compact JSON strings."
  [filter-src json-src]
  (mapv write-json (run (compile-filter filter-src) (parse-json json-src))))
