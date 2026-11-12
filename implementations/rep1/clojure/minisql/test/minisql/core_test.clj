(ns minisql.core-test
  "End-to-end tests of the public API: SQL text in, output text out."
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [minisql.core :as sql]))

(defn- lines [& ls] (str (str/join "\n" ls) "\n"))

(deftest spec-example-1
  (is (= (lines "ann\t120" "dee\t100" "-- 2 rows"
                "NULL\t1\t100\t100.00" "eng\t2\t120\t120.00" "ops\t1\t90\t90.00" "-- 3 rows"
                "error"
                "1\t125" "2\t90" "3\tNULL" "4\t100" "-- 4 rows")
         (sql/run-script
          "CREATE TABLE emp (id INTEGER, name TEXT, dept TEXT, salary INTEGER);
           INSERT INTO emp VALUES (1, 'ann', 'eng', 120), (2, 'bob', 'ops', 90), (3, 'cy', 'eng', NULL), (4, 'dee', NULL, 100);
           SELECT name, salary FROM emp WHERE salary >= 100 ORDER BY salary DESC;
           SELECT dept, COUNT(*), SUM(salary), AVG(salary) FROM emp GROUP BY dept;
           SELECT * FROM nosuch;
           UPDATE emp SET salary = salary + 5 WHERE dept = 'eng';
           SELECT id, salary FROM emp;"))))

(deftest spec-example-2
  (is (= (lines "c\ts" "a\tr" "b\tq" "aa\tr" "-- 4 rows"
                "a\taa" "-- 1 rows"
                "1\t4" "2\t1" "-- 2 rows"
                "3\t-3\t1\tNULL\t1\t1\tNULL\t1" "-- 1 rows")
         (sql/run-script
          "CREATE TABLE a (x INTEGER, s TEXT);
           CREATE TABLE b (y INTEGER, t TEXT);
           INSERT INTO a VALUES (3, 'c'), (1, 'a'), (2, 'b'), (1, 'aa');
           INSERT INTO b VALUES (1, 'p'), (2, 'q'), (1, 'r'), (3, 's');
           SELECT s, t FROM a, b WHERE x = y AND t != 'p';
           SELECT p.s, q.s FROM a p INNER JOIN a q ON p.x = q.x AND p.s < q.s;
           SELECT x, COUNT(*) AS n FROM a, b WHERE x = y GROUP BY x ORDER BY n DESC, x LIMIT 2;
           SELECT 7 / 2, -7 / 2, 7 % -3, 1 / 0, 'B' < 'a', 1 < 'a', NULL = NULL, 'Ab_c' LIKE 'ab%';"))))

(deftest spec-example-3
  (is (= (lines "NULL\t20" "1\t30" "1\tNULL" "2\t10" "2\t40" "-- 5 rows"
                "2\t40" "2\t10" "1\t30" "1\tNULL" "NULL\t20" "-- 5 rows"
                "2" "-- 1 rows"
                "1\t30" "-- 1 rows"
                "3\t10\t2\t26.67" "-- 1 rows"
                "-- 0 rows")
         (sql/run-script
          "CREATE TABLE t (k INTEGER, v INTEGER);
           INSERT INTO t VALUES (2, 10), (NULL, 20), (1, 30), (2, 40), (1, NULL);
           SELECT k, v FROM t ORDER BY k;
           SELECT k, v FROM t ORDER BY k DESC, v DESC;
           SELECT k FROM t GROUP BY k HAVING COUNT(v) = 2;
           SELECT k, v FROM t WHERE k = 1 OR v = 20 LIMIT 1 OFFSET 1;
           DELETE FROM t WHERE v IS NULL OR k IS NULL;
           SELECT COUNT(*), MIN(v), MAX(k), AVG(v) FROM t;
           SELECT 1 FROM t WHERE 0;"))))

(defn- out [script] (sql/run-script script))

(deftest empty-and-comment-only-input
  (is (= "" (out "")))
  (is (= "" (out " \n\t -- nothing ; here\n ;; ; ")))
  (is (= (lines "2" "-- 1 rows") (out "SELECT 1 + 1")) "final ; is optional"))

(deftest errors-leave-the-database-alone
  (is (= (lines "error" "-- 0 rows")
         (out "CREATE TABLE t (a INTEGER, b INTEGER);
               INSERT INTO t VALUES (1, 2), (3);
               SELECT * FROM t;")))
  (is (= (lines "error" "1\t2" "-- 1 rows")
         (out "CREATE TABLE t (a INTEGER, b INTEGER);
               INSERT INTO t VALUES (1, 2);
               UPDATE t SET a = 5, nosuch = 1;
               SELECT * FROM t;"))))

(deftest error-conditions
  (doseq [script ["CREATE TABLE t (a INTEGER); CREATE TABLE T (b TEXT);"
                  "CREATE TABLE t (a INTEGER, A TEXT);"
                  "CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (a);"
                  "CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (COUNT(*));"
                  "CREATE TABLE t (a INTEGER); SELECT b FROM t;"
                  "CREATE TABLE t (a INTEGER); CREATE TABLE u (a INTEGER); SELECT a FROM t, u;"
                  "CREATE TABLE t (a INTEGER); SELECT t.a FROM t x;"
                  "CREATE TABLE t (a INTEGER); SELECT * FROM t, t;"
                  "CREATE TABLE t (a INTEGER); SELECT * FROM t WHERE COUNT(*) > 0;"
                  "CREATE TABLE t (a INTEGER); SELECT a FROM t GROUP BY a HAVING a;SELECT a, COUNT(*) FROM t;"
                  "CREATE TABLE t (a INTEGER); SELECT COUNT(COUNT(*)) FROM t;"
                  "CREATE TABLE t (a INTEGER, b INTEGER); SELECT b FROM t GROUP BY a;"
                  "CREATE TABLE t (a INTEGER); SELECT a FROM t ORDER BY 2;"
                  "CREATE TABLE t (a INTEGER); SELECT a FROM t ORDER BY 0;"
                  "CREATE TABLE t (a INTEGER); UPDATE t SET a = SUM(a);"
                  "CREATE TABLE t (a INTEGER); DELETE FROM t WHERE MAX(a) = 1;"
                  "SELECT a;" "SELECT *;" "SELECT 1 FROM nosuch;"]]
    (testing script
      (is (str/ends-with? (out script) "error\n")))))

(deftest unterminated-string-swallows-the-rest
  (is (= (lines "1" "-- 1 rows" "error")
         (out "SELECT 1; SELECT 'abc; SELECT 2;"))))

(deftest invalid-token-affects-only-its-statement
  (is (= (lines "error" "2" "-- 1 rows") (out "SELECT 1 @ 2; SELECT 2;"))))

(deftest order-by-forms
  (let [setup "CREATE TABLE t (x INTEGER, y INTEGER);
               INSERT INTO t VALUES (2, 1), (1, 2), (3, 0);"]
    (is (= (lines "3\t0" "2\t1" "1\t2" "-- 3 rows") (out (str setup "SELECT x, y FROM t ORDER BY y;")))
        "ASC order, by an unselected-position column") 
    (is (= (lines "1\t2" "2\t1" "3\t0" "-- 3 rows") (out (str setup "SELECT * FROM t ORDER BY 1;"))))
    (is (= (lines "2\t1" "1\t2" "0\t3" "-- 3 rows") (out (str setup "SELECT y a, x b FROM t ORDER BY b;")))
        "alias refers to the item")
    (is (= (lines "2\t1" "1\t2" "3\t0" "-- 3 rows") (out (str setup "SELECT x, y FROM t ORDER BY 1 + 0, 'a';")))
        "only a bare literal is an ordinal; constants keep table order")
    (is (= (lines "1" "-- 1 rows") (out (str setup "SELECT x FROM t ORDER BY x LIMIT 1;"))))
    (is (= (lines "2" "-- 1 rows") (out (str setup "SELECT x FROM t ORDER BY x LIMIT 1 OFFSET 1;"))))))

(deftest alias-shadows-column-in-order-by
  (is (= (lines "1" "2" "-- 2 rows")
         (out "CREATE TABLE t (a INTEGER, b INTEGER);
               INSERT INTO t VALUES (1, 2), (2, 1);
               SELECT b AS a FROM t ORDER BY a;"))))

(deftest aggregates
  (is (= (lines "0\tNULL\tNULL\tNULL\tNULL" "-- 1 rows")
         (out "CREATE TABLE t (a INTEGER);
               SELECT COUNT(*), SUM(a), MIN(a), MAX(a), AVG(a) FROM t;")))
  (is (= (lines "-- 0 rows")
         (out "CREATE TABLE t (a INTEGER); SELECT a, COUNT(*) FROM t GROUP BY a;")))
  (is (= (lines "2\t1\ta\tc" "-- 1 rows")
         (out "CREATE TABLE t (a INTEGER, s TEXT);
               INSERT INTO t VALUES (1, 'c'), (1, 'a'), (NULL, 'b');
               SELECT COUNT(a), COUNT(*) - 1, MIN(s), MAX(s) FROM t WHERE a = 1 OR a IS NULL AND s = 'x' OR s = 'c' OR s = 'a';")))
  (is (= (lines "-1.50" "-- 1 rows") (out "CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (-1), (-2); SELECT AVG(a) FROM t;")))
  (is (= (lines "0.00" "-- 1 rows")
         (out (str "CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (-1)"
                   (apply str (repeat 200 ", (0)")) "; SELECT AVG(a) FROM t;")))
      "-0.00 never prints")
  (is (= (lines "1" "-- 1 rows")
         (out "CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (1), (3);
               SELECT 1 FROM t GROUP BY a HAVING AVG(a) = 1 ORDER BY AVG(a);"))
      "REAL compares with INTEGER")
  (is (= (lines "x\t2" "y\t1" "-- 2 rows")
         (out "CREATE TABLE t (g TEXT, v INTEGER);
               INSERT INTO t VALUES ('y', 1), ('x', 1), ('x', 2);
               SELECT g, COUNT(*) FROM t GROUP BY g ORDER BY COUNT(*) DESC;"))))

(deftest grouping-distinguishes-types-and-null
  (is (= (lines "NULL\t1" "1\t1" "1\t1" "-- 3 rows")
         (out "CREATE TABLE t (k TEXT);
               INSERT INTO t VALUES ('1'), (NULL), (1);
               SELECT k, COUNT(*) FROM t GROUP BY k;"))))

(deftest joins
  (let [setup "CREATE TABLE a (x INTEGER, s TEXT);
               CREATE TABLE b (y INTEGER, t TEXT);
               INSERT INTO a VALUES (1, 'a'), (NULL, 'n'), (2, 'b'), (1, 'c');
               INSERT INTO b VALUES (1, 'p'), (NULL, 'q'), (1, 'r'), (3, 's');"]
    (is (= (lines "a\tp" "a\tr" "c\tp" "c\tr" "-- 4 rows")
           (out (str setup "SELECT s, t FROM a, b WHERE x = y;")))
        "outer table order, then inner; NULL keys never match")
    (is (= (lines "a\tr" "c\tr" "-- 2 rows")
           (out (str setup "SELECT s, t FROM a JOIN b ON a.x = b.y AND t > 'q';"))))
    (is (= (lines "-- 0 rows")
           (out (str setup "SELECT s, t FROM a, b WHERE x = y AND 0;"))))
    (is (= (lines "-- 0 rows")
           (out (str setup "SELECT s, t FROM a, b WHERE x = y AND y > 5;"))))
    (is (= (lines "16" "-- 1 rows")
           (out (str setup "SELECT COUNT(*) FROM a, b;"))))
    (is (= (lines "a\ta" "a\tc" "b\tb" "c\ta" "c\tc" "-- 5 rows")
           (out (str setup "SELECT l.s, r.s FROM a l, a r WHERE l.x = r.x;"))))
    (is (= (lines "a\tp" "a\tr" "c\tp" "c\tr" "-- 4 rows")
           (out (str setup "SELECT s, t FROM a, b WHERE x + 0 = y * 1;")))
        "join keys can be arbitrary expressions")
    (is (= (lines "1\ta\t1\tp" "-- 1 rows")
           (out (str setup "SELECT * FROM a, b WHERE a.x = b.y AND s = 'a' AND t = 'p';"))))))

(deftest update-semantics
  (is (= (lines "2\t1" "-- 1 rows")
         (out "CREATE TABLE t (a INTEGER, b INTEGER);
               INSERT INTO t VALUES (1, 2);
               UPDATE t SET a = b, b = a;
               SELECT * FROM t;")))
  (is (= (lines "1\t5" "-- 1 rows")
         (out "CREATE TABLE acct (id INTEGER, bal INTEGER);
               INSERT INTO acct VALUES (1, 4);
               UPDATE acct SET bal = acct.bal + 1 WHERE acct.id = 1;
               SELECT * FROM acct;")))
  (is (= (lines "error")
         (out "CREATE TABLE t (a INTEGER); UPDATE t SET b = 1;"))))

(deftest text-and-null-semantics
  (is (= (lines "0\t1\t1\t1\tNULL\t0\t1" "-- 1 rows")
         (out "SELECT 1 = '1', 1 < 'a', 100 < '0', '' < 'a', 'a' LIKE NULL, 'É' LIKE 'é', 12345 LIKE '12%';")))
  (is (= (lines "NULL\t0\tNULL\t1\t0\tNULL" "-- 1 rows")
         (out "SELECT NULL AND 1, NULL AND 0, NULL OR 0, NULL OR 1, NOT 1, NOT NULL;")))
  (is (= (lines "1\t0\t1" "-- 1 rows")
         (out "SELECT NULL IS NULL, 1 IS NULL, 1 IS NOT NULL;")))
  (is (= (lines "5\t5\t0" "-- 1 rows") (out "SELECT --5
                                                5, - -5, -0;")))
  (is (= (lines "NULL" "-- 1 rows") (out "SELECT 1 + NULL;")))
  (is (= (lines "hello world" "-- 1 rows") (out "SELECT 'hello world';")))
  (is (= (lines "héllo" "-- 1 rows") (out "SELECT 'héllo';"))))

(deftest keywords-are-case-insensitive-and-count-is-not-reserved
  (is (= (lines "2" "-- 1 rows")
         (out "create table T (Count integer);
               insert into t values (1), (2);
               select max ( COUNT ) from T;"))))

(deftest api-results
  (let [{:keys [db results]} (sql/execute-script (sql/empty-db)
                                                 "CREATE TABLE t (a INTEGER);
                                                  INSERT INTO t VALUES (1), (2);
                                                  SELECT a FROM t; SELECT FROM;")]
    (is (= [{:type :ok} {:type :ok} {:type :rows :rows [[1] [2]]}] (butlast results)))
    (is (= :error (:type (last results))))
    (is (= {:rows [[1] [2]]} (select-keys (get-in db [:tables "t"]) [:rows])))
    (testing "the database is a value that can be continued"
      (is (= [[6]] (-> (sql/execute-script db "INSERT INTO t VALUES (3); SELECT SUM(a) FROM t;")
                       :results last :rows))))))
