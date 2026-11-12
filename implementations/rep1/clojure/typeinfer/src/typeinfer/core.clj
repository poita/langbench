(ns typeinfer.core
  "Hindley-Milner type inference for a small ML-like language.

  The public API:

  * [[infer-source]]  – program text in, the printed report out;
  * [[infer-program]] – program text in, a lazy sequence of result maps out;
  * [[initial-env]], [[infer-decl]] – the same, one declaration at a time,
    for callers that manage the environment themselves;
  * [[type->string]]  – render an inferred type.

  A *result* is one of

      {:name \"id\"  :type \"'a -> 'a\"}   ; let / let rec declaration
      {:name nil    :type \"int\"}         ; bare expression
      {:error :unify | :occurs | :unbound}  ; declaration that failed

  Inference is recursive, so very deeply nested programs need a deep stack:
  run them inside [[with-deep-stack]] (the CLI does)."
  (:require [clojure.string :as str]
            [typeinfer.infer :as infer]
            [typeinfer.parser :as parser]
            [typeinfer.printer :as printer]))

(def initial-env
  "The initial environment containing the built-in functions
  (`not fst snd hd tl null length map fold`)."
  infer/initial-env)

(def type->string
  "Render an inferred type; variables are named `'a`, `'b`, ... in order of
  first appearance."
  printer/type->string)

(defn infer-decl
  "Infer one parsed declaration (see `typeinfer.parser`) in `env`.
  Returns `[env' result]`. A failing declaration yields `{:error kind}` and
  leaves the environment unchanged."
  [env decl]
  (try
    (let [[env' ty] (infer/infer-decl env decl)]
      [env' {:name (:name decl) :type (printer/type->string ty)}])
    (catch clojure.lang.ExceptionInfo e
      (let [kind (:kind (ex-data e))]
        (if (#{:unify :occurs :unbound} kind)
          [env {:error kind}]
          (throw e))))))

(defn infer-program
  "Lazily infer every declaration of the program text `src`, in order,
  starting from `env` (default: [[initial-env]]). Returns a sequence of
  result maps. A syntax error throws `ex-info` (`{:kind :syntax}`) when the
  offending declaration is reached; earlier results are unaffected."
  ([src] (infer-program (initial-env) src))
  ([env src]
   ((fn step [env decls]
      (lazy-seq
       (when-let [decls (seq decls)]
         (let [[env' r] (infer-decl env (first decls))]
           (cons r (step env' (rest decls)))))))
    env (parser/parse-decls src))))

(defn format-result
  "The output line (without newline) for a result map."
  [{:keys [name type error]}]
  (cond
    error (str "error: " (clojure.core/name error))
    name (str name " : " type)
    :else (str "- : " type)))

(defn infer-source
  "Infer the program text `src` and return the full report: one
  newline-terminated line per declaration."
  [src]
  (let [sb (StringBuilder.)]
    (doseq [r (infer-program src)]
      (.append sb ^String (format-result r))
      (.append sb \newline))
    (str sb)))

(defn with-deep-stack
  "Call `f` (no arguments) on a thread with a `stack-bytes` stack (default
  1 GiB) and return its result, rethrowing any exception on the caller's
  thread."
  ([f] (with-deep-stack f (* 1024 1024 1024)))
  ([f stack-bytes]
   (let [result (promise)
         t (Thread. nil
                    (fn [] (deliver result (try {:ok (f)} (catch Throwable e {:err e}))))
                    "typeinfer" (long stack-bytes))]
     (.start t)
     (let [{:keys [ok err]} @result]
       (if err (throw err) ok)))))
