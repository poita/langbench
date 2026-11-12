//! End-to-end tests: run SQL scripts through the library and compare the
//! rendered output with the expected text.

use minisql::Database;

fn run(script: &str) -> String {
    let mut out = Vec::new();
    Database::new().run_script_to(script, &mut out).unwrap();
    String::from_utf8(out).unwrap()
}

#[test]
fn example_employees() {
    let out = run("
CREATE TABLE emp (id INTEGER, name TEXT, dept TEXT, salary INTEGER);
INSERT INTO emp VALUES (1, 'ann', 'eng', 120), (2, 'bob', 'ops', 90), (3, 'cy', 'eng', NULL), (4, 'dee', NULL, 100);
SELECT name, salary FROM emp WHERE salary >= 100 ORDER BY salary DESC;
SELECT dept, COUNT(*), SUM(salary), AVG(salary) FROM emp GROUP BY dept;
SELECT * FROM nosuch;
UPDATE emp SET salary = salary + 5 WHERE dept = 'eng';
SELECT id, salary FROM emp;
");
    assert_eq!(
        out,
        "ann\t120\ndee\t100\n-- 2 rows\n\
         NULL\t1\t100\t100.00\neng\t2\t120\t120.00\nops\t1\t90\t90.00\n-- 3 rows\n\
         error\n\
         1\t125\n2\t90\n3\tNULL\n4\t100\n-- 4 rows\n"
    );
}

#[test]
fn example_joins() {
    let out = run("
CREATE TABLE a (x INTEGER, s TEXT);
CREATE TABLE b (y INTEGER, t TEXT);
INSERT INTO a VALUES (3, 'c'), (1, 'a'), (2, 'b'), (1, 'aa');
INSERT INTO b VALUES (1, 'p'), (2, 'q'), (1, 'r'), (3, 's');
SELECT s, t FROM a, b WHERE x = y AND t != 'p';
SELECT p.s, q.s FROM a p INNER JOIN a q ON p.x = q.x AND p.s < q.s;
SELECT x, COUNT(*) AS n FROM a, b WHERE x = y GROUP BY x ORDER BY n DESC, x LIMIT 2;
SELECT 7 / 2, -7 / 2, 7 % -3, 1 / 0, 'B' < 'a', 1 < 'a', NULL = NULL, 'Ab_c' LIKE 'ab%';
");
    assert_eq!(
        out,
        "c\ts\na\tr\nb\tq\naa\tr\n-- 4 rows\n\
         a\taa\n-- 1 rows\n\
         1\t4\n2\t1\n-- 2 rows\n\
         3\t-3\t1\tNULL\t1\t1\tNULL\t1\n-- 1 rows\n"
    );
}

#[test]
fn example_ordering_and_limits() {
    let out = run("
CREATE TABLE t (k INTEGER, v INTEGER);
INSERT INTO t VALUES (2, 10), (NULL, 20), (1, 30), (2, 40), (1, NULL);
SELECT k, v FROM t ORDER BY k;
SELECT k, v FROM t ORDER BY k DESC, v DESC;
SELECT k FROM t GROUP BY k HAVING COUNT(v) = 2;
SELECT k, v FROM t WHERE k = 1 OR v = 20 LIMIT 1 OFFSET 1;
DELETE FROM t WHERE v IS NULL OR k IS NULL;
SELECT COUNT(*), MIN(v), MAX(k), AVG(v) FROM t;
SELECT 1 FROM t WHERE 0;
");
    assert_eq!(
        out,
        "NULL\t20\n1\t30\n1\tNULL\n2\t10\n2\t40\n-- 5 rows\n\
         2\t40\n2\t10\n1\t30\n1\tNULL\nNULL\t20\n-- 5 rows\n\
         2\n-- 1 rows\n\
         1\t30\n-- 1 rows\n\
         3\t10\t2\t26.67\n-- 1 rows\n\
         -- 0 rows\n"
    );
}

#[test]
fn errors_have_no_effect() {
    let out = run("
CREATE TABLE t (a INTEGER, b INTEGER);
INSERT INTO t VALUES (1, 2), (3);
INSERT INTO t VALUES (1, a);
INSERT INTO t VALUES (1, COUNT(*));
UPDATE t SET a = 1, zzz = 2;
CREATE TABLE T (x INTEGER);
CREATE TABLE u (x INTEGER, X TEXT);
SELECT COUNT(*) FROM t;
SELECT a FROM t HAVING a = 1;
SELECT a, COUNT(*) FROM t;
SELECT a FROM t ORDER BY 2;
SELECT 1 OFFSET 1;
SELECT * FROM t t1, t t1;
SELECT t.a FROM t x;
SELECT a FROM t, t u;
");
    assert_eq!(out, "error\nerror\nerror\nerror\nerror\nerror\n0\n-- 1 rows\nerror\nerror\nerror\nerror\nerror\nerror\nerror\n");
}

#[test]
fn lexical_edge_cases() {
    // Unterminated string swallows the rest of the input.
    assert_eq!(run("SELECT 1; SELECT 'abc; SELECT 2;"), "1\n-- 1 rows\nerror\n");
    // `--` is always a comment; `;` in strings and comments is not a terminator.
    assert_eq!(run("SELECT 1 --5\n; SELECT ';' -- ;\n"), "1\n-- 1 rows\n;\n-- 1 rows\n");
    assert_eq!(run("SELECT 1 @ 2; SELECT 2"), "error\n2\n-- 1 rows\n");
    assert_eq!(run(";; -- nothing\n  ;"), "");
    assert_eq!(run("select 'it''s'"), "it's\n-- 1 rows\n");
}

#[test]
fn count_is_not_reserved() {
    let out = run("CREATE TABLE t (count INTEGER); INSERT INTO t VALUES (4), (5);
                   SELECT count, count (*) FROM t GROUP BY count;");
    assert_eq!(out, "4\t1\n5\t1\n-- 2 rows\n");
}

#[test]
fn order_by_alias_and_ordinal() {
    let out = run("CREATE TABLE a (x INTEGER, y INTEGER);
                   INSERT INTO a VALUES (1, 30), (2, 10), (3, 20);
                   SELECT y AS v, x FROM a ORDER BY v;
                   SELECT *, x FROM a ORDER BY 3 DESC;
                   SELECT x FROM a ORDER BY 1 + 0 DESC;
                   SELECT x FROM a ORDER BY 0;");
    assert_eq!(
        out,
        "10\t2\n20\t3\n30\t1\n-- 3 rows\n\
         3\t20\t3\n2\t10\t2\n1\t30\t1\n-- 3 rows\n\
         1\n2\n3\n-- 3 rows\nerror\n"
    );
}

#[test]
fn avg_rounding_and_real_comparison() {
    let out = run("CREATE TABLE t (g INTEGER, v INTEGER);
                   INSERT INTO t VALUES (1,1),(1,1),(1,1),(1,1),(1,1),(1,1),(1,1),(1,2),
                                        (2,-1),(2,-1),(2,-1),(2,-1),(2,-1),(2,-1),(2,-1),(2,-2);
                   SELECT g, AVG(v) FROM t GROUP BY g;
                   SELECT g FROM t GROUP BY g HAVING AVG(v) < 0;
                   SELECT AVG(v) = 0 FROM t WHERE g = 3;");
    assert_eq!(out, "1\t1.13\n2\t-1.13\n-- 2 rows\n2\n-- 1 rows\nNULL\n-- 1 rows\n");
}

#[test]
fn hash_join_matches_nested_loop_order() {
    let out = run("CREATE TABLE a (k INTEGER, v TEXT); CREATE TABLE b (k INTEGER, w TEXT);
                   INSERT INTO a VALUES (1,'a1'),(NULL,'an'),(2,'a2'),(1,'a3');
                   INSERT INTO b VALUES (1,'b1'),(2,'b2'),(NULL,'bn'),(1,'b3');
                   SELECT v, w FROM a, b WHERE a.k = b.k;
                   SELECT v, w FROM a JOIN b ON a.k + 1 = b.k - 1 AND v < w;");
    assert_eq!(
        out,
        "a1\tb1\na1\tb3\na2\tb2\na3\tb1\na3\tb3\n-- 5 rows\n-- 0 rows\n"
    );
}

#[test]
fn library_api() {
    use minisql::{Output, Value};
    let mut db = Database::new();
    db.execute("create table t (a integer)").unwrap();
    db.execute("insert into t values (1), (2)").unwrap();
    assert_eq!(db.table("T").unwrap().rows.len(), 2);
    let Output::Rows(rs) = db.execute("select sum(a) from t").unwrap() else { panic!() };
    assert_eq!(rs.rows, vec![vec![Value::Int(3)]]);
    assert!(db.execute("select 1; select 2").is_err());
    assert_eq!(db.run_script("select 1; bogus; select 2").len(), 3);
}
