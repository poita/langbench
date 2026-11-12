(ns sat.dimacs
  "Reading DIMACS CNF text and writing solver results."
  (:require [clojure.string :as str])
  (:import [java.io BufferedReader Reader StringReader]))

(defn- blank? [^String s] (str/blank? s))

(defn- tokens [^String line]
  (str/split (str/trim line) #"[ \t]+"))

(defn- parse-int ^long [^String tok]
  (try (Long/parseLong tok)
       (catch NumberFormatException _
         (throw (ex-info (str "invalid integer in DIMACS input: " (pr-str tok)) {:token tok})))))

(defn parse
  "Parses DIMACS CNF text from `in` (a String or a java.io.Reader).

  Returns `{:num-vars V, :clauses [[lit ...] ...]}`.  Comment lines (first
  non-blank character `c`) and blank lines are ignored anywhere; clauses are
  runs of non-zero integers terminated by 0 and may span lines or share a
  line.  Throws `ex-info` on a missing header, a non-integer token, or a
  final clause lacking its terminating 0."
  [in]
  (let [^Reader rdr (if (string? in) (StringReader. ^String in) in)
        br (BufferedReader. rdr)]
    (loop [header nil clauses (transient []) cur (transient [])]
      (if-let [^String line (.readLine br)]
        (let [t (str/trim line)]
          (cond
            (or (.isEmpty t) (= \c (.charAt t 0)))
            (recur header clauses cur)

            (= \p (.charAt t 0))
            (let [[_ fmt v c] (tokens t)]
              (when (or header (not= fmt "cnf"))
                (throw (ex-info "bad or duplicate problem line" {:line line})))
              (recur {:num-vars (parse-int v) :num-clauses (parse-int c)} clauses cur))

            :else
            (do
              (when-not header
                (throw (ex-info "clause data before the problem line" {:line line})))
              (let [[clauses cur]
                    (reduce (fn [[clauses cur] tok]
                              (let [k (parse-int tok)]
                                (if (zero? k)
                                  [(conj! clauses (persistent! cur)) (transient [])]
                                  [clauses (conj! cur k)])))
                            [clauses cur]
                            (tokens t))]
                (recur header clauses cur)))))
        (do
          (when-not header
            (throw (ex-info "missing problem line" {})))
          (when (pos? (count cur))
            (throw (ex-info "last clause is not terminated by 0" {})))
          {:num-vars (:num-vars header)
           :clauses (persistent! clauses)})))))

(defn format-result
  "Formats a result map from `sat.solver/solve` as the text the CLI prints:
  `UNSAT\\n`, or `SAT\\n` followed by the model line ending in 0."
  ^String [{:keys [status model]}]
  (if (= status :sat)
    (let [sb (StringBuilder. "SAT\n")]
      (doseq [l model] (.append sb (long l)) (.append sb \space))
      (.append sb "0\n")
      (.toString sb))
    "UNSAT\n"))
