(ns sat.dimacs
  "Reading and writing the DIMACS CNF format."
  (:require [clojure.string :as str]))

(defn- blank-split [^String line]
  (str/split (str/trim line) #"[ \t]+"))

(defn parse
  "Parses DIMACS CNF text. Returns `{:num-vars V :num-clauses C :clauses
  [[lit ...] ...]}`.

  Comment lines (first non-blank character `c`) and blank lines are ignored
  anywhere; the `p cnf V C` header gives the counts; every other line holds
  integers, and a clause is a run of non-zero integers terminated by `0`
  (clauses may span lines and several may share a line). A trailing
  unterminated clause is ignored."
  [^String text]
  (loop [lines (str/split text #"\n")
         nv 0 nc 0
         cur (transient []) clauses (transient [])]
    (if-let [line (first lines)]
      (let [t (str/trim line)]
        (cond
          (or (empty? t) (= \c (first t))) (recur (rest lines) nv nc cur clauses)
          (= \p (first t)) (let [[_ _ v c] (blank-split t)]
                             (recur (rest lines) (Long/parseLong v) (Long/parseLong c) cur clauses))
          :else (let [[cur clauses]
                      (reduce (fn [[cur clauses] tok]
                                (let [k (Long/parseLong tok)]
                                  (if (zero? k)
                                    [(transient []) (conj! clauses (persistent! cur))]
                                    [(conj! cur k) clauses])))
                              [cur clauses]
                              (blank-split t))]
                  (recur (rest lines) nv nc cur clauses))))
      {:num-vars nv :num-clauses nc :clauses (persistent! clauses)})))

(defn format-result
  "Renders a result of `sat.core/solve` as SAT-competition style text:
  `UNSAT\\n`, or `SAT\\n<l1> ... <lV> 0\\n`."
  [{:keys [status model]}]
  (if (= status :sat)
    (str "SAT\n" (str/join " " (concat model [0])) "\n")
    "UNSAT\n"))
