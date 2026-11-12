(ns jsonschema.core
  "Public API of the JSON Schema 2020-12 validator.

      (require '[jsonschema.core :as js])

      (def v (js/validator {\"type\" \"integer\" \"minimum\" 1}))
      (js/valid? v 3)    ;=> true   (numbers are BigDecimal, see jsonschema.json)

  Schemas and instances are JSON values in the data model of
  [[jsonschema.json]]: `nil`, booleans, numbers, strings, vectors and maps
  with string keys. Use [[jsonschema.json/parse]] to obtain them from text.

  Evaluation recurses in proportion to the nesting depth of the schema and
  instance; run on a thread with a large stack (see [[with-large-stack]])
  for deeply nested input."
  (:require [jsonschema.schema :as schema]))

(set! *warn-on-reflection* true)

(defrecord Validator [root])

(defn validator
  "Compiles `schema` (a boolean or a map) into a validator.

  Options:

  * `:remotes` — a map from absolute URI string to schema document. They can
    be referenced from `schema` (and from each other) by URI; documents are
    indexed like the root schema, with the map key as their retrieval URI."
  ([schema] (validator schema {}))
  ([schema {:keys [remotes]}]
   (let [ctx (schema/compile-documents (cons ["" schema] (seq remotes)))]
     (->Validator (schema/compile-schema ctx schema "")))))

(defn valid?
  "True when `instance` satisfies the schema compiled into `validator`."
  [^Validator validator instance]
  (boolean ((:root validator) instance [])))

(defn with-large-stack*
  "Calls the function `f` with no arguments on a new thread whose stack is
  `stack-bytes` large (default 1 GiB) and returns its result, rethrowing any
  exception on the calling thread."
  ([f] (with-large-stack* f (* 1024 1024 1024)))
  ([f stack-bytes]
   (let [result (promise)
         t (Thread. nil
                    (fn []
                      (deliver result (try {:value (f)} (catch Throwable e {:error e}))))
                    "jsonschema-worker"
                    (long stack-bytes))]
     (.start t)
     (let [{:keys [value error]} @result]
       (if error (throw error) value)))))

(defmacro with-large-stack
  "Evaluates `body` on a thread with a large stack; see [[with-large-stack*]]."
  [& body]
  `(with-large-stack* (fn [] ~@body)))
