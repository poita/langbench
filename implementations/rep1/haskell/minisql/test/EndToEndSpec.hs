{-# LANGUAGE OverloadedStrings #-}

module EndToEndSpec (spec) where

import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Test.Hspec

import MiniSQL

-- | Run a script and return its output as lines.
run :: [String] -> [String]
run ls = lines (TL.unpack (renderScript (T.pack (unlines ls))))

spec :: Spec
spec = do
  describe "examples from the specification" $ do
    it "example 1: filter, group, update" $
      run
        [ "CREATE TABLE emp (id INTEGER, name TEXT, dept TEXT, salary INTEGER);"
        , "INSERT INTO emp VALUES (1, 'ann', 'eng', 120), (2, 'bob', 'ops', 90), (3, 'cy', 'eng', NULL), (4, 'dee', NULL, 100);"
        , "SELECT name, salary FROM emp WHERE salary >= 100 ORDER BY salary DESC;"
        , "SELECT dept, COUNT(*), SUM(salary), AVG(salary) FROM emp GROUP BY dept;"
        , "SELECT * FROM nosuch;"
        , "UPDATE emp SET salary = salary + 5 WHERE dept = 'eng';"
        , "SELECT id, salary FROM emp;"
        ]
        `shouldBe` [ "ann\t120", "dee\t100", "-- 2 rows"
                   , "NULL\t1\t100\t100.00", "eng\t2\t120\t120.00", "ops\t1\t90\t90.00", "-- 3 rows"
                   , "error"
                   , "1\t125", "2\t90", "3\tNULL", "4\t100", "-- 4 rows"
                   ]
    it "example 2: joins, self join, arithmetic" $
      run
        [ "CREATE TABLE a (x INTEGER, s TEXT);"
        , "CREATE TABLE b (y INTEGER, t TEXT);"
        , "INSERT INTO a VALUES (3, 'c'), (1, 'a'), (2, 'b'), (1, 'aa');"
        , "INSERT INTO b VALUES (1, 'p'), (2, 'q'), (1, 'r'), (3, 's');"
        , "SELECT s, t FROM a, b WHERE x = y AND t != 'p';"
        , "SELECT p.s, q.s FROM a p INNER JOIN a q ON p.x = q.x AND p.s < q.s;"
        , "SELECT x, COUNT(*) AS n FROM a, b WHERE x = y GROUP BY x ORDER BY n DESC, x LIMIT 2;"
        , "SELECT 7 / 2, -7 / 2, 7 % -3, 1 / 0, 'B' < 'a', 1 < 'a', NULL = NULL, 'Ab_c' LIKE 'ab%';"
        ]
        `shouldBe` [ "c\ts", "a\tr", "b\tq", "aa\tr", "-- 4 rows"
                   , "a\taa", "-- 1 rows"
                   , "1\t4", "2\t1", "-- 2 rows"
                   , "3\t-3\t1\tNULL\t1\t1\tNULL\t1", "-- 1 rows"
                   ]
    it "example 3: ordering, having, limit, delete" $
      run
        [ "CREATE TABLE t (k INTEGER, v INTEGER);"
        , "INSERT INTO t VALUES (2, 10), (NULL, 20), (1, 30), (2, 40), (1, NULL);"
        , "SELECT k, v FROM t ORDER BY k;"
        , "SELECT k, v FROM t ORDER BY k DESC, v DESC;"
        , "SELECT k FROM t GROUP BY k HAVING COUNT(v) = 2;"
        , "SELECT k, v FROM t WHERE k = 1 OR v = 20 LIMIT 1 OFFSET 1;"
        , "DELETE FROM t WHERE v IS NULL OR k IS NULL;"
        , "SELECT COUNT(*), MIN(v), MAX(k), AVG(v) FROM t;"
        , "SELECT 1 FROM t WHERE 0;"
        ]
        `shouldBe` [ "NULL\t20", "1\t30", "1\tNULL", "2\t10", "2\t40", "-- 5 rows"
                   , "2\t40", "2\t10", "1\t30", "1\tNULL", "NULL\t20", "-- 5 rows"
                   , "2", "-- 1 rows"
                   , "1\t30", "-- 1 rows"
                   , "3\t10\t2\t26.67", "-- 1 rows"
                   , "-- 0 rows"
                   ]

  describe "script structure" $ do
    it "prints nothing for empty or comment-only input" $ do
      run [] `shouldBe` []
      run ["  -- nothing", ";;  ;"] `shouldBe` []
    it "runs a final statement without a semicolon" $
      run ["SELECT 1"] `shouldBe` ["1", "-- 1 rows"]
    it "stops at an unterminated string" $
      run ["SELECT 1;", "SELECT 'abc;", "SELECT 2;"] `shouldBe` ["1", "-- 1 rows", "error"]
    it "recovers after an invalid token" $
      run ["SELECT @;", "SELECT 2;"] `shouldBe` ["error", "2", "-- 1 rows"]

  describe "errors leave the database untouched" $ do
    it "an INSERT with one bad row inserts nothing" $
      run
        [ "CREATE TABLE t (a INTEGER, b INTEGER);"
        , "INSERT INTO t VALUES (1, 2), (3);"
        , "INSERT INTO t VALUES (1, a);"
        , "SELECT COUNT(*) FROM t;"
        ]
        `shouldBe` ["error", "error", "0", "-- 1 rows"]
    it "an UPDATE with an unknown column changes nothing" $
      run
        [ "CREATE TABLE t (a INTEGER);"
        , "INSERT INTO t VALUES (1);"
        , "UPDATE t SET a = 2, zz = 3;"
        , "SELECT a FROM t;"
        ]
        `shouldBe` ["error", "1", "-- 1 rows"]
    it "reports each documented semantic error" $
      run
        [ "CREATE TABLE t (a INTEGER, b TEXT);"
        , "CREATE TABLE t (a INTEGER);"
        , "CREATE TABLE u (a INTEGER, A TEXT);"
        , "SELECT zz FROM t;"
        , "SELECT a FROM t, t;"
        , "SELECT a FROM t x, t y;"
        , "SELECT t.a FROM t x;"
        , "SELECT a, COUNT(*) FROM t;"
        , "SELECT SUM(COUNT(a)) FROM t;"
        , "SELECT a FROM t WHERE COUNT(*) > 1;"
        , "SELECT a FROM t ORDER BY 2 + 0, 3;"
        , "SELECT a FROM t ORDER BY 0;"
        , "SELECT * ;"
        , "SELECT a;"
        , "UPDATE t SET a = COUNT(*);"
        , "INSERT INTO t VALUES (COUNT(*), 'x');"
        , "SELECT DISTINCT a FROM t;"
        ]
        `shouldBe` replicate 16 "error"

  describe "SELECT semantics" $ do
    let setup =
          [ "CREATE TABLE t (k INTEGER, v INTEGER, s TEXT);"
          , "INSERT INTO t VALUES (1, 10, 'x'), (2, NULL, 'y'), (1, 30, 'z');"
          ]
    it "resolves ORDER BY aliases and ordinals" $
      run (setup ++ ["SELECT v AS w, s FROM t ORDER BY w DESC, 2;"])
        `shouldBe` ["30\tz", "10\tx", "NULL\ty", "-- 3 rows"]
    it "counts the columns of * for ordinals" $
      run (setup ++ ["SELECT *, k FROM t ORDER BY 4 DESC, 2 DESC;"])
        `shouldBe` ["2\tNULL\ty\t2", "1\t30\tz\t1", "1\t10\tx\t1", "-- 3 rows"]
    it "treats non-literal ORDER BY terms as expressions" $
      run (setup ++ ["SELECT s FROM t ORDER BY 1 + 0;"]) `shouldBe` ["x", "y", "z", "-- 3 rows"]
    it "lets a column be named count" $
      run ["CREATE TABLE c (count INTEGER);", "INSERT INTO c VALUES (4);", "SELECT count, count (*) FROM c GROUP BY count;"]
        `shouldBe` ["4\t1", "-- 1 rows"]
    it "yields one group for an aggregate over no rows" $
      run (setup ++ ["SELECT COUNT(*), SUM(v), MAX(s) FROM t WHERE k = 9;"])
        `shouldBe` ["0\tNULL\tNULL", "-- 1 rows"]
    it "yields no groups for GROUP BY over no rows" $
      run (setup ++ ["SELECT k, COUNT(*) FROM t WHERE k = 9 GROUP BY k;"])
        `shouldBe` ["-- 0 rows"]
    it "groups NULL with NULL and orders groups ascending" $
      run
        [ "CREATE TABLE g (a INTEGER);"
        , "INSERT INTO g VALUES (2), (NULL), (1), (NULL), (2);"
        , "SELECT a, COUNT(*) FROM g GROUP BY a;"
        ]
        `shouldBe` ["NULL\t2", "1\t1", "2\t2", "-- 3 rows"]
    it "rounds AVG half away from zero and never prints -0.00" $
      run
        [ "CREATE TABLE n (a INTEGER);"
        , "INSERT INTO n VALUES (1),(1),(1),(1),(1),(1),(1),(2);"
        , "SELECT AVG(a) FROM n;"
        , "DELETE FROM n;"
        , "INSERT INTO n VALUES (-1), (-1), (-1), (-1), (-1), (-1), (-1), (-2);"
        , "SELECT AVG(a) FROM n;"
        , "SELECT AVG(a) = -1.13 FROM n;"
        ]
        `shouldBe` ["1.13", "-- 1 rows", "-1.13", "-- 1 rows", "error"]
    it "compares AVG with integers" $
      run ["CREATE TABLE n (a INTEGER);", "INSERT INTO n VALUES (1), (3);", "SELECT 2 = AVG(a), AVG(a) < 3, AVG(a) IS NULL FROM n;"]
        `shouldBe` ["1\t1\t0", "-- 1 rows"]
    it "emits join pairs in nested-loop order for a hash join" $
      run
        [ "CREATE TABLE a (x INTEGER);"
        , "CREATE TABLE b (y INTEGER, t TEXT);"
        , "INSERT INTO a VALUES (2), (1), (2), (NULL);"
        , "INSERT INTO b VALUES (2, 'p'), (NULL, 'n'), (1, 'q'), (2, 'r');"
        , "SELECT x, t FROM a, b WHERE x = y;"
        ]
        `shouldBe` ["2\tp", "2\tr", "1\tq", "2\tp", "2\tr", "-- 5 rows"]
    it "applies one-sided and residual conjuncts around the join key" $
      run
        [ "CREATE TABLE a (x INTEGER, u INTEGER);"
        , "CREATE TABLE b (y INTEGER, w INTEGER);"
        , "INSERT INTO a VALUES (1, 1), (1, 5), (2, 1);"
        , "INSERT INTO b VALUES (1, 3), (1, 9), (2, 3);"
        , "SELECT u, w FROM a JOIN b ON a.x = b.y AND u < w AND w < 9 AND 1 = 1;"
        ]
        `shouldBe` ["1\t3", "1\t3", "-- 2 rows"]
    it "supports a self join with aliases" $
      run
        [ "CREATE TABLE a (x INTEGER);"
        , "INSERT INTO a VALUES (1), (2);"
        , "SELECT p.x, q.x FROM a AS p, a AS q WHERE p.x < q.x;"
        ]
        `shouldBe` ["1\t2", "-- 1 rows"]
    it "evaluates LIMIT 0 and OFFSET past the end" $
      run (setup ++ ["SELECT k FROM t LIMIT 0;", "SELECT k FROM t LIMIT 5 OFFSET 7;"])
        `shouldBe` ["-- 0 rows", "-- 0 rows"]
    it "implements three-valued logic" $
      run ["SELECT NULL AND 0, NULL OR 1, NOT NULL, 1 AND NULL, 0 OR NULL, NOT 5;"]
        `shouldBe` ["0\t1\tNULL\tNULL\tNULL\t0", "-- 1 rows"]
    it "implements C-style division and remainder" $
      run ["SELECT -7 / 2, -7 % 3, 7 % -3, 5 % 0, -(-3);"]
        `shouldBe` ["-3\t-1\t1\tNULL\t3", "-- 1 rows"]
    it "applies LIKE to integers" $
      run ["SELECT 12345 LIKE '12%', 'a' NOT LIKE 'A', NULL LIKE 'a';"]
        `shouldBe` ["1\t0\tNULL", "-- 1 rows"]
    it "UPDATE assigns from old values" $
      run
        [ "CREATE TABLE s (a INTEGER, b INTEGER);"
        , "INSERT INTO s VALUES (1, 2);"
        , "UPDATE s SET a = b, b = a;"
        , "SELECT a, b FROM s;"
        ]
        `shouldBe` ["2\t1", "-- 1 rows"]
