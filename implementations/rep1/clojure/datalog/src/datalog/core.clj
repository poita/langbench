(ns datalog.core
  "Public API of the Datalog engine.

  ```clojure
  (require '[datalog.core :as dl])

  (def model
    (dl/solve (dl/parse-program
                \"edge(1, 2). edge(2, 3).
                 path(X, Y) :- edge(X, Y).
                 path(X, Z) :- edge(X, Y), path(Y, Z).\")))

  (dl/query model \"path(1, X)\")  ;=> [[1 2] [1 3]]
  ```

  See `datalog.syntax` for the data representation of programs. Failures
  are reported by exceptions whose `ex-data` has a `:type` of
  `:datalog/parse-error`, `:datalog/unsafe-rule` or
  `:datalog/not-stratifiable`; `error?` recognises the last two."
  (:require [clojure.string :as str]
            [datalog.eval :as eval]
            [datalog.parser :as parser]
            [datalog.query :as query]
            [datalog.syntax :as syn]))

(defn parse-program
  "Parses program text into `{:rules [...] :queries [...]}`."
  [text]
  (parser/parse-program text))

(defn parse-atom
  "Parses an atom such as `\"path(1, X)\"`."
  [text]
  (parser/parse-atom text))

(defn solve
  "Checks that `program` is safe and stratifiable, then computes its perfect
  model with semi-naive evaluation. `program` is a map as returned by
  `parse-program`, or a string of program text. Returns a model for use with
  `query`; throws on an unsafe or unstratifiable program."
  [program]
  (eval/solve (if (string? program) (parse-program program) program)))

(defn query
  "The tuples of `model` matching `q`, an atom map or a string such as
  `\"path(1, X)\"`, as a vector of vectors of constants (`Long`s and
  `Keyword`s), sorted in the constant order of the specification."
  [model q]
  (query/answers model (if (string? q) (parse-atom q) q)))

(defn run-program
  "Parses and solves `text` and answers each of its queries in order.
  Returns a vector of `{:query atom :tuples [[constant ...] ...]}`."
  [text]
  (let [program (parse-program text)
        model (solve program)]
    (mapv (fn [q] {:query q :tuples (query model q)}) (:queries program))))

(defn format-answers
  "Renders the result of `run-program` in the output format of the
  specification: each matching tuple as `p(v1, v2)` on its own line, then
  `-- N`."
  [answers]
  (let [sb (StringBuilder.)]
    (doseq [{:keys [query tuples]} answers]
      (doseq [t tuples]
        (.append sb (syn/format-atom (:pred query) t))
        (.append sb \newline))
      (.append sb (str "-- " (count tuples) "\n")))
    (str sb)))

(defn error?
  "True when `e` is the failure of a program that is unsafe or not
  stratifiable."
  [^Throwable e]
  (contains? #{:datalog/unsafe-rule :datalog/not-stratifiable} (:type (ex-data e))))
