(ns typeinfer.properties-test
  "Property-based tests (test.check) over randomly generated programs."
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [typeinfer.core :as core]
            [typeinfer.printer]))

(def ^:private names ["x" "y" "z" "f" "g" "id" "map" "fst" "hd" "undefined"])

(defn- expr-gen [depth]
  (let [leaf (gen/one-of [(gen/elements ["0" "1" "42" "true" "false" "()" "[]"])
                          (gen/elements names)])]
    (if (zero? depth)
      leaf
      (let [sub (expr-gen (dec depth))]
        (gen/one-of
         [leaf
          (gen/fmap (fn [[f a]] (str "(" f ") (" a ")")) (gen/tuple sub sub))
          (gen/fmap (fn [[x e]] (str "(fun " x " -> " e ")")) (gen/tuple (gen/elements ["x" "y" "f"]) sub))
          (gen/fmap (fn [[x a b]] (str "(let " x " = " a " in " b ")"))
                    (gen/tuple (gen/elements ["x" "y" "g"]) sub sub))
          (gen/fmap (fn [[x a b]] (str "(let rec " x " p = " a " in " b ")"))
                    (gen/tuple (gen/elements ["f" "g"]) sub sub))
          (gen/fmap (fn [[c a b]] (str "(if " c " then " a " else " b ")")) (gen/tuple sub sub sub))
          (gen/fmap (fn [[a b]] (str "(" a ", " b ")")) (gen/tuple sub sub))
          (gen/fmap (fn [[a b]] (str "[" a "; " b "]")) (gen/tuple sub sub))
          (gen/fmap (fn [[a op b]] (str "(" a ") " op " (" b ")"))
                    (gen/tuple sub (gen/elements ["+" "*" "<" "&&" "::" "="]) sub))])))))

(def ^:private program-gen
  (gen/fmap (fn [es] (str/join (map #(str % ";;\n") es)))
            (gen/vector (expr-gen 4) 0 6)))

(defn- classify [line]
  (cond (str/starts-with? line "- : ") :type
        (re-matches #"error: (unify|occurs|unbound)" line) :error
        :else :bad))

(defspec one-well-formed-line-per-declaration 300
  (prop/for-all [src program-gen]
    (let [n (count (re-seq #";;" src))
          ls (remove str/blank? (str/split-lines (core/infer-source src)))]
      (and (= n (count ls))
           (every? #(not= :bad (classify %)) ls)))))

(defspec inference-is-deterministic 100
  (prop/for-all [src program-gen]
    (= (core/infer-source src) (core/infer-source src))))

(defspec rendering-uses-canonical-variable-names 200
  (prop/for-all [src program-gen]
    ;; The variables of a printed type are 'a, 'b, ... in order of first appearance.
    (every? (fn [line]
              (let [vars (distinct (re-seq #"'[a-z][0-9]*" line))
                    expected (map #(typeinfer.printer/var-name %) (range (count vars)))]
                (= vars expected)))
            (remove #(str/starts-with? % "error") (str/split-lines (core/infer-source src))))))
