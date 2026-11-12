(ns minisql.parser-test
  (:require [clojure.test :refer [deftest is testing]]
            [minisql.lexer :as lexer]
            [minisql.parser :as parser]))

(defn parse [sql] (parser/parse-statement (first (lexer/statements sql))))
(defn expr [sql] (-> (parse (str "SELECT " sql)) :items first :expr))
(defn syntax-error? [sql]
  (try (parse sql) false
       (catch clojure.lang.ExceptionInfo e (= :syntax (:minisql.error/kind (ex-data e))))))

(deftest precedence-and-associativity
  (is (= [:sub [:sub [:lit 10] [:lit 4]] [:lit 3]] (expr "10 - 4 - 3")))
  (is (= [:add [:lit 1] [:mul [:lit 2] [:lit 3]]] (expr "1 + 2 * 3")))
  (is (= [:mod [:neg [:lit 5]] [:lit 3]] (expr "-5 % 3")))
  (is (= [:not [:eq [:col nil "a"] [:lit 1]]] (expr "NOT a = 1")))
  (is (= [:is-null [:add [:col nil "a"] [:lit 1]]] (expr "a + 1 IS NULL")))
  (is (= [:eq [:lt [:lit 1] [:lit 2]] [:lit 1]] (expr "1 < 2 = 1")))
  (is (= [:or [:lit 1] [:and [:lit 2] [:lit 3]]] (expr "1 OR 2 AND 3")))
  (is (= [:not [:like [:col nil "a"] [:lit "x"]]] (expr "a NOT LIKE 'x'")))
  (is (= [:is-not-null [:col nil "a"]] (expr "a IS NOT NULL")))
  (is (= [:eq [:col nil "a"] [:lit 1]] (expr "a == 1"))))

(deftest aggregate-calls
  (is (= [:agg :count :star] (expr "COUNT(*)")))
  (is (= [:agg :count :star] (expr "count --c\n (*)")))
  (is (= [:agg :sum [:col nil "x"]] (expr "SUM(x)")))
  (is (= [:col nil "count"] (expr "count")))
  (is (syntax-error? "SELECT sum(*) FROM t"))
  (is (syntax-error? "SELECT foo(1)")))

(deftest select-shape
  (let [q (parse "SELECT a x, t.b AS y, * FROM emp e INNER JOIN dept AS d ON e.d = d.id
                  WHERE a > 1 GROUP BY a, t.b HAVING COUNT(*) > 1
                  ORDER BY x DESC, 2 LIMIT 5 OFFSET 2")]
    (is (= :select (:type q)))
    (is (= ["x" "y" nil] (map :alias (:items q))))
    (is (= [{:table "emp" :alias "e"} {:table "dept" :alias "d"}] (:tables q)))
    (is (= :and (first (:where q))))
    (is (= [[:col nil "a"] [:col "t" "b"]] (:group-by q)))
    (is (= ["x" nil] (map :name (:order-by q))))
    (is (= [nil 2] (map :ordinal (:order-by q))))
    (is (= [true false] (map :desc (:order-by q))))
    (is (= [5 2] ((juxt :limit :offset) q)))))

(deftest other-statements
  (is (= {:type :create :table "t" :columns [["a" :integer] ["b" :text]]}
         (parse "create table T (A integer, b TEXT)")))
  (is (= [[[:lit 1] [:lit nil]] [[:lit 2] [:lit "x"]]]
         (:rows (parse "INSERT INTO t VALUES (1, NULL), (2, 'x')"))))
  (is (= {:type :delete :table "t" :where nil} (parse "DELETE FROM t")))
  (is (= [["a" [:col nil "b"]] ["b" [:col nil "a"]]]
         (:set (parse "UPDATE t SET a = b, b = a")))))

(deftest syntax-errors
  (doseq [sql ["DROP TABLE t" "SELECT" "SELECT 1 +" "SELECT * FROM a LEFT JOIN b ON 1"
               "SELECT * FROM a, b, c" "SELECT 1 FROM t WHERE a IN (1)"
               "SELECT 1 FROM t WHERE a BETWEEN 1 AND 2"
               "SELECT 'a' || 'b'" "INSERT INTO t (a) VALUES (1)"
               "CREATE TABLE t (a)" "CREATE TABLE t (a REAL)" "CREATE TABLE t ()"
               "CREATE TABLE t (text TEXT)" "SELECT a AS left FROM t"
               "SELECT 1 FROM t LIMIT -1" "SELECT 1 FROM t OFFSET 1"
               "SELECT 1 FROM t HAVING 1" "SELECT 1 FROM t GROUP BY a + 1"
               "SELECT 1.5" "SELECT @" "SELECT 'abc" "SELECT (SELECT 1)"
               "SELECT 1 1 1" "SELECT * AS x FROM t" "SELECT a FROM t INNER b"
               "SELECT 1 FROM a JOIN b" "UPDATE t SET a == 1"
               "SELECT 1 IS NOT" "SELECT 1 NOT 2"]]
    (testing sql (is (syntax-error? sql)))))
