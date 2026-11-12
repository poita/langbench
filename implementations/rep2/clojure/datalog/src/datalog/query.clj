(ns datalog.query
  "Answering queries against a computed model."
  (:require [datalog.analysis :as analysis]
            [datalog.constants :as constants]
            [datalog.relation :as rel]))

(set! *warn-on-reflection* true)

(defn- matcher
  "A predicate on rank tuples for the query atom `atom`: constants must be
  equal and a variable repeated in the query must match the same value."
  [{:keys [args]} rank]
  (let [pats (vec args)
        n (count pats)]
    (fn [tuple]
      (loop [i 0, env {}]
        (if (== i n)
          true
          (let [p (pats i), v (tuple i)]
            (cond
              (symbol? p) (if (contains? env p)
                            (when (== (long v) (long (env p))) (recur (inc i) env))
                            (recur (inc i) (assoc env p v)))
              :else (when (== (long v) (long (rank p))) (recur (inc i) env)))))))))

(defn answer
  "The tuples of `model` matching the query `atom` (`{:pred .. :args ..}`), as
  a vector of vectors of constants in ascending tuple order.  A relation the
  program never mentions is empty."
  [{:keys [relations table]} atom]
  (let [{:keys [rank constants]} table
        r (get relations (analysis/pred-id atom))
        match (matcher atom #(get rank % -1))]
    (->> (some-> r rel/tuples)
         (filter match)
         (sort compare)
         (mapv (fn [t] (mapv #(constants (long %)) t))))))

(defn format-answer
  "Formats the `tuples` answering a query on predicate `pred` as the lines
  `pred(v1, v2)` followed by `-- N`; every line ends with a newline."
  ^String [pred tuples]
  (let [sb (StringBuilder.)]
    (doseq [t tuples]
      (.append sb ^String pred)
      (.append sb "(")
      (doseq [[i c] (map-indexed vector t)]
        (when (pos? i) (.append sb ", "))
        (.append sb (constants/format-constant c)))
      (.append sb ")\n"))
    (.append sb "-- ")
    (.append sb (count tuples))
    (.append sb "\n")
    (.toString sb)))
