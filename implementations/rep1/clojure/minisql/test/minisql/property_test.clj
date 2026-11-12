(ns minisql.property-test
  "Properties of the query engine checked against straightforward oracles."
  (:require [clojure.string :as str]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [minisql.core :as sql]
            [minisql.value :as v]))

(def ^:private small-int (gen/one-of [(gen/return nil) (gen/choose -3 3)]))
(def ^:private rows-gen (gen/vector (gen/tuple small-int small-int) 0 25))

(defn- lit [x] (if (nil? x) "NULL" (str x)))

(defn- insert-sql [table rows]
  (if (empty? rows)
    ""
    (str "INSERT INTO " table " VALUES "
         (str/join ", " (map (fn [[a b]] (str "(" (lit a) ", " (lit b) ")")) rows)) ";")))

(defn- select-rows [script]
  (-> (sql/execute-script (sql/empty-db) script) :results last :rows))

(defspec order-by-is-a-stable-sort 200
  (prop/for-all [rows rows-gen
                 desc gen/boolean]
    (let [script (str "CREATE TABLE t (k INTEGER, v INTEGER);" (insert-sql "t" rows)
                      "SELECT k, v FROM t ORDER BY k " (if desc "DESC" "ASC") ";")
          cmp (fn [a b] (let [c (v/compare-values (first a) (first b))] (if desc (- c) c)))]
      (= (vec (sort cmp (map vec rows))) (select-rows script)))))

(defspec joins-match-nested-loop-oracle 200
  (prop/for-all [a rows-gen b rows-gen]
    (let [script (str "CREATE TABLE a (x INTEGER, p INTEGER); CREATE TABLE b (y INTEGER, q INTEGER);"
                      (insert-sql "a" a) (insert-sql "b" b)
                      "SELECT x, p, y, q FROM a, b WHERE x = y AND p <= q;")
          expected (vec (for [[x p] a [y q] b
                              :when (and x y (= x y) p q (<= p q))]
                          [x p y q]))]
      (= expected (select-rows script)))))

(defspec group-by-counts-match-frequencies 200
  (prop/for-all [rows rows-gen]
    (let [script (str "CREATE TABLE t (k INTEGER, v INTEGER);" (insert-sql "t" rows)
                      "SELECT k, COUNT(*), COUNT(v), SUM(v) FROM t GROUP BY k;")
          expected (->> (group-by first rows)
                        (map (fn [[k rs]]
                               (let [vs (keep second rs)]
                                 [k (count rs) (count vs) (when (seq vs) (reduce + vs))])))
                        (sort-by first v/compare-values)
                        vec)]
      (= expected (select-rows script)))))

(defspec delete-and-update-keep-row-order 200
  (prop/for-all [rows rows-gen]
    (let [script (str "CREATE TABLE t (k INTEGER, v INTEGER);" (insert-sql "t" rows)
                      "DELETE FROM t WHERE k > 0; UPDATE t SET v = 7 WHERE k IS NULL;"
                      "SELECT k, v FROM t;")
          expected (->> rows
                        (remove (fn [[k _]] (and k (> k 0))))
                        (mapv (fn [[k v]] (if (nil? k) [k 7] [k v]))))]
      (= expected (select-rows script)))))
