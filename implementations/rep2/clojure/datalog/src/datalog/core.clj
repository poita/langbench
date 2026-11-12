(ns datalog.core
  "Public API of the Datalog engine: stratified Datalog with negation and
  comparisons, evaluated bottom-up (semi-naive).

  Typical use:

      (require '[datalog.core :as dl])

      (dl/run-string \"edge(a, b). edge(b, c).
                      path(X, Y) :- edge(X, Y).
                      path(X, Z) :- edge(X, Y), path(Y, Z).
                      ?- path(a, X).\")
      ;; => \"path(a, b)\\npath(a, c)\\n-- 2\\n\"

  or, to keep the model and query it repeatedly:

      (let [program (dl/parse \"...\")
            model   (dl/solve program)]        ; throws on unsafe/unstratifiable
        (dl/query model \"path\" [\"a\" 'X]))

  Terms: an integer is a `Long`, an identifier a `String`, a variable a
  `Symbol` (see [[datalog.parser]])."
  (:require [datalog.analysis :as analysis]
            [datalog.eval :as eval]
            [datalog.parser :as parser]
            [datalog.query :as query]))

(set! *warn-on-reflection* true)

(defn parse
  "Parses program text into a program (a vector of clauses).  Throws
  `ex-info` with `:type :parse-error` on malformed input."
  [text]
  (parser/parse-program text))

(defn check
  "Checks safety, then stratifiability, of `program`.  Returns nil when the
  program is fine, otherwise `{:error :unsafe, :rules [...]}` or
  `{:error :unstratifiable}`."
  [program]
  (if-let [bad (seq (analysis/unsafe-rules program))]
    {:error :unsafe :rules (vec bad)}
    (when-not (analysis/stratify program)
      {:error :unstratifiable})))

(defn- evaluate [program]
  (eval/evaluate program (analysis/stratify program)))

(defn solve
  "Computes the model of `program`.  Throws `ex-info` with
  `:type :invalid-program` and the result of [[check]] under `:problem` when
  the program is unsafe or not stratifiable."
  [program]
  (when-let [problem (check program)]
    (throw (ex-info (str "invalid program: " (name (:error problem)))
                    {:type :invalid-program :problem problem})))
  (evaluate program))

(defn query
  "The tuples of `model` matching the atom `pred(args...)`, a vector of tuples
  of constants in ascending order.  `args` are constants or variable symbols;
  a variable repeated in `args` must match equal values.  Constants unknown to
  the program simply match nothing."
  [model pred args]
  (query/answer model {:pred pred :args (vec args)}))

(defn query-clauses
  "The query atoms of `program`, in source order."
  [program]
  (into [] (comp (filter #(= :query (:type %))) (map :atom)) program))

(defn run-string
  "Runs the program text `text`: returns the complete output of the
  command-line tool as a string.  That is `\"error\\n\"` for an unsafe or
  unstratifiable program, and otherwise the formatted answers of its queries
  in order."
  [text]
  (let [program (parse text)]
    (if (check program)
      "error\n"
      (let [model (evaluate program)
            sb (StringBuilder.)]
        (doseq [{:keys [pred args]} (query-clauses program)]
          (.append sb ^String (query/format-answer pred (query model pred args))))
        (.toString sb)))))
