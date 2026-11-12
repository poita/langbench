(ns spreadsheet.property-test
  "Property test: after any sequence of edits, the incrementally maintained
  sheet agrees with a naive from-scratch evaluation."
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [spreadsheet.cell :as cell]
            [spreadsheet.core :as ss]
            [spreadsheet.eval :as eval]
            [spreadsheet.parser :as parser]))

(def names (vec (for [r (range 1 5) c ["A" "B" "C"]] (str c r))))

(def gen-name (gen/elements names))

(def gen-expr
  (gen/recursive-gen
   (fn [inner]
     (gen/one-of
      [(gen/fmap (fn [[a op b]] (str a op b))
                 (gen/tuple inner (gen/elements ["+" "-" "*" "/" "&" "<" "=" "<>" ">="]) inner))
       (gen/fmap #(str "(" % ")") inner)
       (gen/fmap #(str "-" %) inner)
       (gen/fmap (fn [[c a b]] (str "IF(" c "," a "," b ")")) (gen/tuple inner inner inner))
       (gen/fmap (fn [[f a b]] (str f "(" a ":" b ")"))
                 (gen/tuple (gen/elements ["SUM" "MIN" "MAX" "AVG" "COUNT"]) gen-name gen-name))
       (gen/fmap (fn [[f a b]] (str f "(" a "," b ")"))
                 (gen/tuple (gen/elements ["SUM" "MAX" "COUNT"]) inner inner))]))
   (gen/one-of [gen-name
                (gen/fmap str (gen/choose -5 5))
                (gen/elements ["0" "\"a\"" "\"\"" "AAA1" "2.5"])])))

(def gen-content
  (gen/one-of [(gen/fmap str (gen/choose -9 9))
               (gen/elements ["\"s\"" "\"\""])
               (gen/fmap #(str "=" %) gen-expr)]))

(def gen-edit
  (gen/one-of [(gen/tuple (gen/return :set) gen-name gen-content)
               (gen/tuple (gen/return :clear) gen-name (gen/return nil))]))

(defn- oracle
  "Evaluates a map of {name content} from scratch."
  [contents]
  (let [parsed (into {} (for [[n c] contents] [(cell/parse-ref n) (parser/parse-content c)]))
        reach (fn reach [seen id]
                (reduce (fn [seen d] (if (seen d) seen (reach (conj seen d) d)))
                        seen (:deps (parsed id))))
        cyclic? (fn [id] (contains? (reach #{} id) id))
        cyc (set (filter cyclic? (keys parsed)))
        step (fn [vals]
               (into {} (for [[id {:keys [ast]}] parsed]
                          [id {:value (if (cyc id)
                                        :error/cycle
                                        (let [v (eval/ev vals ast)] (if (nil? v) 0.0 v)))}])))
        vals (nth (iterate step {}) (+ 2 (count parsed)))]
    (into {} (for [[id c] vals] [(cell/id->name id) (:value c)]))))

(defspec incremental-matches-from-scratch 150
  (prop/for-all [edits (gen/vector gen-edit 1 25)]
    (let [[sheet contents]
          (reduce (fn [[s m] [op n c]]
                    (if (= op :set)
                      [(ss/set-cell s n c) (assoc m n c)]
                      [(ss/clear-cell s n) (dissoc m n)]))
                  [(ss/empty-sheet) {}] edits)
          expected (oracle contents)]
      (and (= (set (keys expected)) (set (map first (ss/dump sheet))))
           (every? (fn [[n v]] (= v (ss/value sheet n))) expected)))))
