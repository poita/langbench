(ns depresolve.property-test
  "Checks the iterative implementation against a direct, recursive transcription
  of the specified search on small random registries."
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [depresolve.core :as core]
            [depresolve.range :as range]
            [depresolve.version :as v]))

(defn- reference-resolve
  "SPEC.md's pseudo-code, verbatim, over the plain registry data."
  [registry root]
  (letfn [(candidates [nm rng]
            (->> (get registry nm)
                 keys
                 (map (fn [s] [(v/parse s) s]))
                 (filter (fn [[n _]] (range/in-range? (range/parse rng) n)))
                 (sort-by first >)
                 (map second)))
          (go [pending chosen]
            (if (empty? pending)
              chosen
              (let [[nm rng] (first pending)
                    rest* (rest pending)]
                (if-let [cv (get chosen nm)]
                  (when (range/in-range? (range/parse rng) (v/parse cv))
                    (go rest* chosen))
                  (some (fn [ver]
                          (go (concat (get-in registry [nm ver]) rest*)
                              (assoc chosen nm ver)))
                        (candidates nm rng))))))]
    (some-> (go root {}) (->> (into (sorted-map))))))

(def gen-name (gen/elements ["a" "b" "c" "d" "e"]))
(def gen-ver (gen/fmap (fn [[x y z]] (str x "." y "." z))
                       (gen/tuple (gen/choose 0 2) (gen/choose 0 2) (gen/choose 0 2))))
(def gen-range
  (gen/frequency
   [[6 (gen/return "*")]
    [2 (gen/fmap #(str ">=" %) gen-ver)]
    [1 gen-ver]
    [3 (gen/fmap #(str "^" %) gen-ver)]
    [2 (gen/fmap #(str "~" %) gen-ver)]
    [2 (gen/fmap (fn [[op1 a op2 b]] (str op1 a " " op2 b))
              (gen/tuple (gen/elements ["<" "<=" ">" ">="]) gen-ver
                         (gen/elements ["<" "<=" ">" ">="]) gen-ver))]
    [1 (gen/fmap (fn [[op a]] (str op a)) (gen/tuple (gen/elements ["<" "<=" ">" ">="]) gen-ver))]]))
(def gen-reqs
  (gen/fmap (fn [names] (vec names))
            (gen/bind (gen/set gen-name {:max-elements 2})
                      (fn [names] (apply gen/tuple
                                         (map #(gen/fmap (fn [r] [% r]) gen-range) names))))))
(def gen-registry
  (gen/fmap (fn [entries]
              (reduce (fn [m [n v reqs]] (assoc-in m [n v] reqs)) {} entries))
            (gen/vector (gen/tuple gen-name gen-ver gen-reqs) 0 30)))

(defspec matches-reference-search 500
  (prop/for-all [registry gen-registry
                 root gen-reqs]
    (= (reference-resolve registry root)
       (core/resolve-deps registry root))))
