(ns datalog.property-test
  "Generative tests: the engine against straightforward reference
  implementations on random graphs."
  (:require [clojure.string :as str]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [datalog.core :as dl]))

(def edges-gen
  (gen/let [n (gen/choose 1 12)
            es (gen/vector (gen/tuple (gen/choose 0 (dec n)) (gen/choose 0 (dec n))) 0 40)]
    {:n n :edges (vec (distinct es))}))

(defn- facts [edges]
  (str/join " " (map (fn [[a b]] (str "edge(" a ", " b ").")) edges)))

(defn- closure
  "Reference transitive closure by iterating to a fixpoint on sets of pairs."
  [edges]
  (loop [r (set edges)]
    (let [r' (into r (for [[a b] r [c d] r :when (= b c)] [a d]))]
      (if (= r r') r (recur r')))))

(defn- run-tuples [text pred]
  (let [model (dl/solve (dl/parse text))]
    (set (map vec (dl/query model pred ['X 'Y])))))

(defspec right-linear-closure-matches-reference 60
  (prop/for-all [{:keys [edges]} edges-gen]
    (= (closure edges)
       (run-tuples (str (facts edges)
                        " path(X, Y) :- edge(X, Y). path(X, Z) :- edge(X, Y), path(Y, Z).")
                   "path"))))

(defspec non-linear-closure-matches-reference 60
  (prop/for-all [{:keys [edges]} edges-gen]
    (= (closure edges)
       (run-tuples (str (facts edges)
                        " path(X, Y) :- edge(X, Y). path(X, Z) :- path(X, Y), path(Y, Z).")
                   "path"))))

(defspec negation-complement-matches-reference 60
  (prop/for-all [{:keys [n edges]} edges-gen]
    (let [reach (closure edges)
          expected (set (for [a (range n) b (range n) :when (not (reach [a b]))] [a b]))
          nodes (str/join " " (map #(str "node(" % ").") (range n)))]
      (= expected
         (run-tuples (str (facts edges) " " nodes
                          " path(X, Y) :- edge(X, Y). path(X, Z) :- edge(X, Y), path(Y, Z)."
                          " unreach(X, Y) :- node(X), node(Y), not path(X, Y).")
                     "unreach")))))

(defspec output-is-sorted-and-counted 40
  (prop/for-all [{:keys [edges]} edges-gen]
    (let [out (dl/run-string (str (facts edges) " ?- edge(X, Y)."))
          ls (str/split-lines out)
          body (vec (butlast ls))]
      (and (= (str "-- " (count edges)) (last ls))
           (= body (vec (sort-by (fn [l] (mapv #(Long/parseLong %) (re-seq #"\d+" l))) body)))))))
