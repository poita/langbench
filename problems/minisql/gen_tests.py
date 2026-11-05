#!/usr/bin/env python3
"""Generates tests/*.in and tests/*.out for the `minisql` problem.

Every test is either an embedded literal (hand-written feature and edge-case
scripts) or produced by a seeded generator, so re-running this script
reproduces the suite exactly. Expected outputs come from reference/main.py run
as a subprocess, and every expected output is then cross-checked against
SQLite (the sqlite3 module) running the same statements one at a time, with
results formatted per SPEC.md and AVG overridden by the spec's exact
two-decimal rounding. Any disagreement aborts generation.
"""
import importlib.util
import os
import random
import sqlite3
import subprocess
import sys

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, 'tests')
REF = os.path.join(HERE, 'reference', 'main.py')

spec = importlib.util.spec_from_file_location('ref', REF)
ref = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ref)

cases = []


def add(name, text):
    if text and not text.endswith('\n'):
        text += '\n'
    cases.append((name, text))


# ---------------------------------------------------------------------------
# SQLite oracle
# ---------------------------------------------------------------------------

class SpecAvg:
    """AVG per SPEC.md: exact SUM/COUNT rounded half away from zero to hundredths."""

    def __init__(self):
        self.s = 0
        self.c = 0

    def step(self, v):
        if v is None:
            return
        self.s += v
        self.c += 1

    def finalize(self):
        if self.c == 0:
            return None
        h = (200 * abs(self.s) + self.c) // (2 * self.c)
        return (-h if self.s < 0 else h) / 100.0


def oracle_fmt(v):
    if v is None:
        return 'NULL'
    if isinstance(v, float):
        h = int(round(v * 100))
        return '%s%d.%02d' % ('-' if h < 0 else '', abs(h) // 100, abs(h) % 100)
    return str(v)


def oracle_sql(src, stmt):
    """Returns the statement's text, with a two-table FROM rewritten to use
    CROSS JOIN so that SQLite keeps the spec's nested-loop order (the left
    table is the outer loop) instead of letting its planner reorder."""
    base, end = stmt[0][2], stmt[-1][3]
    text = src[base:end]
    if stmt[0][0] != 'ID' or stmt[0][1] != 'select':
        return text
    i = next((i for i, t in enumerate(stmt) if t[0] == 'ID' and t[1] == 'from'), None)
    if i is None:
        return text
    j = i + 1
    if j >= len(stmt) or stmt[j][0] != 'ID':
        return text
    j += 1
    if j < len(stmt) and stmt[j][0] == 'ID' and stmt[j][1] == 'as':
        j += 2
    elif j < len(stmt) and stmt[j][0] == 'ID' and stmt[j][1] not in ref.KEYWORDS:
        j += 1
    if j >= len(stmt):
        return text
    t = stmt[j]
    if t[0] == 'OP' and t[1] == ',':
        s, e, r = t[2], t[3], ' CROSS JOIN '
    elif t[0] == 'ID' and t[1] == 'inner' and j + 1 < len(stmt) and stmt[j + 1][1] == 'join':
        s, e, r = t[2], stmt[j + 1][3], 'CROSS JOIN'
    elif t[0] == 'ID' and t[1] == 'join':
        s, e, r = t[2], t[3], 'CROSS JOIN'
    else:
        return text
    return src[base:s] + r + src[e:end]


def oracle(src):
    conn = sqlite3.connect(':memory:')
    conn.create_aggregate('avg', 1, SpecAvg)
    out = []
    for stmt in ref.split_statements(ref.tokenize(src)):
        text = oracle_sql(src, stmt)
        try:
            cur = conn.execute(text)
            if cur.description is not None:
                rows = cur.fetchall()
                for r in rows:
                    out.append('\t'.join(oracle_fmt(v) for v in r))
                out.append('-- %d rows' % len(rows))
        except (sqlite3.Error, sqlite3.Warning):
            out.append('error')
    conn.close()
    return out


# ---------------------------------------------------------------------------
# Hand-written feature tests
# ---------------------------------------------------------------------------

add('create_insert_select', '''
CREATE TABLE t (a INTEGER, b TEXT);
INSERT INTO t VALUES (1, 'one');
INSERT INTO t VALUES (2, 'two'), (3, 'three');
SELECT * FROM t;
SELECT b, a FROM t;
SELECT a FROM t;
SELECT *, a + 1 FROM t;
''')

add('empty_results', '''
CREATE TABLE t (a INTEGER, b TEXT);
SELECT * FROM t;
SELECT COUNT(*) FROM t;
SELECT SUM(a), MIN(a), MAX(b), AVG(a), COUNT(a) FROM t;
SELECT a FROM t GROUP BY a;
SELECT a FROM t ORDER BY a LIMIT 3;
INSERT INTO t VALUES (NULL, NULL);
SELECT * FROM t;
SELECT SUM(a), MIN(a), MAX(b), AVG(a), COUNT(a), COUNT(*) FROM t;
''')

add('expressions_no_from', '''
SELECT 1 + 2 * 3, (1 + 2) * 3, 10 - 4 - 3, 100 / 10 / 5, 2 * 3 % 4;
SELECT 7 / 2, -7 / 2, 7 / -2, -7 / -2, 7 % 3, -7 % 3, 7 % -3, -7 % -3;
SELECT 1 / 0, 5 % 0, -1 / 0, 0 / 5, 0 % 5;
SELECT -5, - -5, -(2 + 3), -2 * 3, - 2 * - 3, 4 - -4;
SELECT 1 = 1, 1 = 2, 1 != 2, 1 <> 1, 1 == 1, 2 < 3, 3 <= 3, 4 > 5, 5 >= 5;
SELECT 'abc' = 'abc', 'abc' < 'abd', 'B' < 'a', '' < 'a', 'abc' < 'abcd', 'ab' > 'a';
SELECT 1 < 'a', 1 = '1', 1 != '1', 100 < '0', 'a' > 1;
SELECT NULL, NULL + 1, 1 - NULL, NULL * NULL, -NULL, NULL / 0, NULL % 2;
SELECT NULL = NULL, NULL != NULL, NULL < 1, 1 > NULL, NULL = 'x';
SELECT 1 + 2 = 3, 1 + 2 < 3 + 1, 1 < 2 = 1, 2 * 3 = 3 * 2;
SELECT 1 = 1 = 1, 1 = 2 = 0, 3 > 2 > 1;
SELECT 123456789012 * 1000, 9223372036854775807, -9223372036854775807 - 1, 0 - 0;
''')

add('null_logic', '''
SELECT NULL AND NULL, NULL AND 1, NULL AND 0, 1 AND NULL, 0 AND NULL, 1 AND 1, 1 AND 0, 0 AND 0;
SELECT NULL OR NULL, NULL OR 1, NULL OR 0, 1 OR NULL, 0 OR NULL, 1 OR 1, 1 OR 0, 0 OR 0;
SELECT NOT NULL, NOT 0, NOT 1, NOT 5, NOT -3, NOT NOT NULL, NOT NOT 7;
SELECT NULL IS NULL, NULL IS NOT NULL, 0 IS NULL, 0 IS NOT NULL, '' IS NULL, (NULL = NULL) IS NULL;
SELECT 1 + 1 IS NULL, NULL + 1 IS NULL, NOT 1 IS NULL, NOT NULL IS NULL;
SELECT 1 OR 0 AND 0, (1 OR 0) AND 0, NOT 1 AND 0, NOT (1 AND 0), 0 OR NOT 0;
SELECT NOT 1 = 2, NOT 1 = 1, NOT 1 < 2 OR 1, 1 AND 2 = 2;
SELECT 5 AND 3, 5 OR 0, -1 AND -1, NOT 1 = 1 AND 1;
CREATE TABLE t (a INTEGER, b INTEGER);
INSERT INTO t VALUES (1, 1), (1, NULL), (NULL, 1), (NULL, NULL), (0, 0), (0, NULL);
SELECT * FROM t WHERE a = 1;
SELECT * FROM t WHERE a != 1;
SELECT * FROM t WHERE NOT a = 1;
SELECT * FROM t WHERE a IS NULL;
SELECT * FROM t WHERE a IS NOT NULL AND b IS NULL;
SELECT * FROM t WHERE a = 1 OR b = 1;
SELECT * FROM t WHERE a = 1 AND b = 1;
SELECT * FROM t WHERE a = b;
SELECT * FROM t WHERE NOT (a = b);
SELECT * FROM t WHERE (a = b) IS NULL;
SELECT * FROM t WHERE a;
SELECT * FROM t WHERE NOT a;
SELECT * FROM t WHERE a + b;
SELECT * FROM t WHERE 1;
SELECT * FROM t WHERE 0;
SELECT * FROM t WHERE NULL;
''')

add('where_comparisons', '''
CREATE TABLE p (id INTEGER, name TEXT, price INTEGER, qty INTEGER);
INSERT INTO p VALUES (1, 'apple', 30, 10), (2, 'banana', 15, 0), (3, 'cherry', 300, 5),
  (4, 'date', 30, NULL), (5, 'elderberry', NULL, 7), (6, 'fig', 8, 12), (7, 'grape', 45, 3);
SELECT id FROM p WHERE price > 20;
SELECT id FROM p WHERE price >= 30 AND qty < 10;
SELECT id FROM p WHERE price < 30 OR qty > 8;
SELECT id FROM p WHERE price * qty >= 150;
SELECT id, price * qty FROM p WHERE price * qty IS NULL;
SELECT id FROM p WHERE name > 'c';
SELECT id FROM p WHERE name >= 'date' AND name <= 'fig';
SELECT id FROM p WHERE name = 'Apple';
SELECT id FROM p WHERE price = 30 AND NOT qty IS NULL;
SELECT id FROM p WHERE NOT price > 20;
SELECT id FROM p WHERE price % 15 = 0;
SELECT id FROM p WHERE (price / 10) * 10 = price;
SELECT id FROM p WHERE id - 1 = qty OR id + 1 = qty;
SELECT name FROM p WHERE price > qty * 5 AND qty > 0;
SELECT id FROM p WHERE price;
SELECT id FROM p WHERE qty;
''')

add('like_patterns', '''
CREATE TABLE w (s TEXT);
INSERT INTO w VALUES ('apple'), ('Apple'), ('APPLE'), ('pineapple'), ('apple pie'), ('a'), (''), ('app_le'), ('50%'), (NULL), ('éclair'), ('ÉCLAIR'), ('café');
SELECT s FROM w WHERE s LIKE 'apple';
SELECT s FROM w WHERE s LIKE 'app%';
SELECT s FROM w WHERE s LIKE '%apple';
SELECT s FROM w WHERE s LIKE '%apple%';
SELECT s FROM w WHERE s LIKE '%';
SELECT s FROM w WHERE s LIKE '';
SELECT s FROM w WHERE s LIKE '_';
SELECT s FROM w WHERE s LIKE 'a____';
SELECT s FROM w WHERE s LIKE 'app_le';
SELECT s FROM w WHERE s LIKE '%\\_%';
SELECT s FROM w WHERE s LIKE '50%';
SELECT s FROM w WHERE s LIKE '5_%';
SELECT s FROM w WHERE s LIKE '%PIE';
SELECT s FROM w WHERE s NOT LIKE '%a%';
SELECT s FROM w WHERE s LIKE 'é%';
SELECT s FROM w WHERE s LIKE '%é';
SELECT s FROM w WHERE s LIKE 'caf_';
SELECT s FROM w WHERE s LIKE '%%%';
SELECT s FROM w WHERE s LIKE NULL;
SELECT s, s LIKE 'a%', s NOT LIKE 'a%' FROM w WHERE s IS NULL OR s = 'a' OR s = 'Apple';
SELECT 'abc' LIKE 'ABC', 'abc' LIKE 'a_c', 'abc' LIKE 'a%c%', 'abc' LIKE 'b%', 12345 LIKE '12%', 'x' LIKE 'x%x';
SELECT s FROM w WHERE s LIKE 'a%' AND s NOT LIKE '%e';
''')

add('order_by', '''
CREATE TABLE t (id INTEGER, k INTEGER, s TEXT);
INSERT INTO t VALUES (1, 3, 'b'), (2, NULL, 'a'), (3, 1, NULL), (4, 3, 'A'), (5, 2, 'b'), (6, NULL, 'c'), (7, 1, ''), (8, -4, 'ab');
SELECT id, k FROM t ORDER BY k;
SELECT id, k FROM t ORDER BY k DESC;
SELECT id, k FROM t ORDER BY k ASC, id DESC;
SELECT id, s FROM t ORDER BY s;
SELECT id, s FROM t ORDER BY s DESC;
SELECT id, k, s FROM t ORDER BY k DESC, s ASC;
SELECT id, k, s FROM t ORDER BY s DESC, k DESC, id;
SELECT id FROM t ORDER BY k * -1;
SELECT id FROM t ORDER BY k IS NULL, id DESC;
SELECT id FROM t ORDER BY s LIKE 'a%' DESC, id;
SELECT id FROM t ORDER BY 1 DESC;
SELECT k, id FROM t ORDER BY 1, 2 DESC;
SELECT id, k + 100 AS kk FROM t ORDER BY kk DESC;
SELECT id, k AS s FROM t ORDER BY s;
SELECT id FROM t ORDER BY 1 + 0;
SELECT id FROM t ORDER BY 'a', id DESC;
SELECT id FROM t ORDER BY id LIMIT 3;
SELECT id FROM t ORDER BY id DESC LIMIT 3 OFFSET 2;
SELECT id FROM t ORDER BY id LIMIT 0;
SELECT id FROM t ORDER BY id LIMIT 100 OFFSET 6;
SELECT id FROM t ORDER BY id LIMIT 2 OFFSET 100;
SELECT id FROM t LIMIT 4;
SELECT id FROM t LIMIT 4 OFFSET 1;
''')

add('order_stability', '''
CREATE TABLE t (id INTEGER, k INTEGER, g TEXT);
INSERT INTO t VALUES (1, 2, 'x'), (2, 1, 'y'), (3, 2, 'x'), (4, 1, 'x'), (5, 2, 'y'), (6, NULL, 'y'), (7, 1, 'y'), (8, NULL, 'x');
SELECT id FROM t ORDER BY k;
SELECT id FROM t ORDER BY k DESC;
SELECT id FROM t ORDER BY g;
SELECT id FROM t ORDER BY g DESC;
SELECT id FROM t ORDER BY g, k;
SELECT id FROM t ORDER BY g DESC, k DESC;
SELECT id FROM t ORDER BY 1 = 1;
SELECT g, COUNT(*) FROM t GROUP BY g;
SELECT k, g, COUNT(*) FROM t GROUP BY k, g;
SELECT k, g, COUNT(*) FROM t GROUP BY g, k;
SELECT k, COUNT(*) AS n FROM t GROUP BY k ORDER BY n;
SELECT k, g FROM t GROUP BY k, g ORDER BY g;
SELECT g, k FROM t GROUP BY g, k ORDER BY k DESC;
DELETE FROM t WHERE id = 3;
INSERT INTO t VALUES (3, 2, 'x');
SELECT id FROM t ORDER BY k;
UPDATE t SET k = 2 WHERE id = 2;
SELECT id FROM t ORDER BY k;
''')

add('update_delete', '''
CREATE TABLE acct (id INTEGER, owner TEXT, bal INTEGER);
INSERT INTO acct VALUES (1, 'ann', 100), (2, 'bob', 50), (3, 'cy', NULL), (4, 'ann', 0), (5, 'dee', 75);
UPDATE acct SET bal = bal + 10 WHERE owner = 'ann';
SELECT * FROM acct;
UPDATE acct SET bal = 0 WHERE bal IS NULL;
SELECT id, bal FROM acct;
UPDATE acct SET bal = bal * 2, owner = 'x' WHERE id >= 4;
SELECT * FROM acct;
UPDATE acct SET id = bal, bal = id;
SELECT * FROM acct;
UPDATE acct SET owner = NULL WHERE owner LIKE '_';
SELECT * FROM acct;
UPDATE acct SET bal = 1 WHERE 0;
SELECT * FROM acct;
UPDATE acct SET bal = -bal WHERE bal > 100 OR owner IS NULL;
SELECT * FROM acct;
DELETE FROM acct WHERE bal < 0;
SELECT * FROM acct;
DELETE FROM acct WHERE owner IS NULL;
SELECT * FROM acct;
DELETE FROM acct WHERE 0;
SELECT COUNT(*) FROM acct;
DELETE FROM acct;
SELECT * FROM acct;
INSERT INTO acct VALUES (9, 'z', 9);
SELECT * FROM acct;
UPDATE acct SET bal = 1;
SELECT * FROM acct;
DELETE FROM acct WHERE NULL;
SELECT COUNT(*) FROM acct;
UPDATE acct SET bal = acct.bal + 1, owner = 'q' WHERE acct.id = 9;
SELECT * FROM acct;
DELETE FROM acct WHERE acct.bal = 2 AND acct.owner = 'q';
SELECT COUNT(*) FROM acct;
''')

add('row_order_after_mutation', '''
CREATE TABLE t (id INTEGER, v INTEGER);
INSERT INTO t VALUES (1, 10), (2, 20), (3, 30), (4, 40), (5, 50);
DELETE FROM t WHERE id = 2;
INSERT INTO t VALUES (6, 60);
SELECT * FROM t;
DELETE FROM t WHERE id = 6;
INSERT INTO t VALUES (7, 70), (8, 80);
SELECT * FROM t;
UPDATE t SET id = 2 WHERE id = 3;
SELECT * FROM t;
DELETE FROM t WHERE id > 4;
DELETE FROM t WHERE id < 2;
SELECT * FROM t;
DELETE FROM t;
INSERT INTO t VALUES (100, 1), (99, 2);
SELECT * FROM t;
SELECT * FROM t ORDER BY v DESC;
''')

add('comma_join', '''
CREATE TABLE a (x INTEGER, s TEXT);
CREATE TABLE b (y INTEGER, t TEXT);
INSERT INTO a VALUES (3, 'c'), (1, 'a'), (2, 'b'), (1, 'aa'), (NULL, 'n');
INSERT INTO b VALUES (1, 'p'), (2, 'q'), (1, 'r'), (3, 's'), (NULL, 'u');
SELECT * FROM a, b;
SELECT * FROM a, b WHERE x = y;
SELECT s, t FROM a, b WHERE a.x = b.y AND t != 'p';
SELECT * FROM b, a WHERE x = y;
SELECT s, t FROM a, b WHERE x < y;
SELECT s, t FROM a, b WHERE x + y = 3;
SELECT s, t FROM a, b WHERE x IS NULL AND y IS NULL;
SELECT a.s, b.t FROM a, b WHERE a.x = b.y ORDER BY b.t DESC, a.s;
SELECT COUNT(*) FROM a, b;
SELECT COUNT(*) FROM a, b WHERE x = y;
SELECT s, t, x * 10 + y FROM a, b WHERE x = y ORDER BY 3, s, t;
SELECT * FROM a, b WHERE x = y LIMIT 2 OFFSET 1;
SELECT x, COUNT(*) FROM a, b WHERE x = y GROUP BY x;
SELECT a.x, SUM(b.y) FROM a, b WHERE a.x >= b.y GROUP BY a.x;
''')

add('inner_join_alias', '''
CREATE TABLE emp (id INTEGER, name TEXT, boss INTEGER, dept TEXT);
CREATE TABLE dept (name TEXT, floor INTEGER);
INSERT INTO emp VALUES (1, 'ann', NULL, 'eng'), (2, 'bob', 1, 'eng'), (3, 'cy', 1, 'ops'), (4, 'dee', 2, 'eng'), (5, 'eve', 3, NULL), (6, 'fay', 9, 'ops');
INSERT INTO dept VALUES ('eng', 3), ('ops', 1), ('hr', 2);
SELECT emp.name, dept.floor FROM emp INNER JOIN dept ON emp.dept = dept.name;
SELECT e.name, d.floor FROM emp AS e JOIN dept AS d ON e.dept = d.name ORDER BY d.floor, e.name;
SELECT e.name, d.floor FROM emp e INNER JOIN dept d ON e.dept = d.name WHERE d.floor > 1 ORDER BY e.id;
SELECT e.name, b.name FROM emp e INNER JOIN emp b ON e.boss = b.id;
SELECT e.name, b.name FROM emp e, emp b WHERE e.boss = b.id ORDER BY b.name, e.name;
SELECT e.id, b.id FROM emp e INNER JOIN emp b ON e.id < b.id AND e.dept = b.dept;
SELECT e.name FROM emp e JOIN emp b ON e.boss = b.id WHERE b.boss IS NULL;
SELECT * FROM emp e JOIN dept d ON 1 WHERE e.id = 1;
SELECT COUNT(*) FROM emp e JOIN dept d ON e.dept = d.name;
SELECT d.name, COUNT(*), MIN(e.name), MAX(e.id) FROM emp e JOIN dept d ON e.dept = d.name GROUP BY d.name;
SELECT e.dept, COUNT(*) FROM emp e JOIN emp b ON e.boss = b.id GROUP BY e.dept ORDER BY 2 DESC, 1;
SELECT id, floor FROM emp INNER JOIN dept ON dept = dept.name ORDER BY id;
SELECT emp.name FROM emp, dept WHERE emp.dept = dept.name AND floor = 3;
SELECT e.name, e.dept FROM emp e WHERE e.boss IS NOT NULL ORDER BY e.name;
''')

add('group_by_aggregates', '''
CREATE TABLE s (student TEXT, subject TEXT, score INTEGER);
INSERT INTO s VALUES ('ann', 'math', 90), ('ann', 'art', 70), ('bob', 'math', 60), ('bob', 'art', NULL), ('cy', 'math', NULL), ('cy', 'art', 85), ('dee', 'math', 75), (NULL, 'art', 50), ('ann', 'math', 80);
SELECT student, COUNT(*), COUNT(score), SUM(score), MIN(score), MAX(score), AVG(score) FROM s GROUP BY student;
SELECT subject, COUNT(*), SUM(score) FROM s GROUP BY subject;
SELECT student, subject, COUNT(*) FROM s GROUP BY student, subject;
SELECT COUNT(*), COUNT(score), COUNT(student), SUM(score), MIN(score), MAX(score), AVG(score) FROM s;
SELECT MIN(student), MAX(student), MIN(subject), MAX(subject) FROM s;
SELECT student, SUM(score) / COUNT(score), SUM(score) % 7, MAX(score) - MIN(score) FROM s GROUP BY student;
SELECT student, COUNT(*) * 2 + 1, -SUM(score), MAX(score) > 80, SUM(score) IS NULL FROM s GROUP BY student;
SELECT student, COUNT(score) FROM s WHERE score >= 75 GROUP BY student;
SELECT subject, MAX(score) FROM s WHERE student LIKE '%n' GROUP BY subject;
SELECT SUM(score + 1), SUM(score * 2), COUNT(score * 0), MIN(score % 10), AVG(score - 100) FROM s;
SELECT student, COUNT(*) FROM s WHERE student IS NOT NULL GROUP BY student;
SELECT COUNT(*), COUNT(*) FROM s;
SELECT student, subject, score FROM s GROUP BY student, subject, score;
''')

add('avg_rounding', '''
CREATE TABLE t (g INTEGER, v INTEGER);
INSERT INTO t VALUES (1, 1), (1, 2), (2, 1), (2, 1), (2, 2), (3, -1), (3, -2), (4, 1), (4, 2), (4, 3), (4, 4), (4, 5), (4, 6), (4, 7), (4, 8);
INSERT INTO t VALUES (5, 0), (5, 0), (5, 1), (6, -1), (6, 0), (6, 0), (7, 1), (7, 1), (7, 1), (7, 1), (7, 1), (7, 1), (7, 1), (7, 1), (7, 2);
INSERT INTO t VALUES (8, 5), (9, -5), (10, 0), (11, 1), (11, 1), (11, 1), (11, 1), (11, 1), (11, 1), (11, 1), (11, 2);
INSERT INTO t VALUES (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 1), (12, 2);
INSERT INTO t VALUES (13, -1), (13, -1), (13, -1), (13, -1), (13, -1), (13, -1), (13, -1), (13, -2);
INSERT INTO t VALUES (14, -1), ''' + ', '.join(['(14, 0)'] * 199) + ''';
INSERT INTO t VALUES (15, -1), ''' + ', '.join(['(15, 0)'] * 200) + ''';
INSERT INTO t VALUES (16, 1), ''' + ', '.join(['(16, 0)'] * 199) + ''';
INSERT INTO t VALUES (17, -3), (17, -2), (17, -2), (17, -2);
SELECT g, COUNT(*), SUM(v), AVG(v) FROM t GROUP BY g;
SELECT AVG(v) FROM t;
SELECT AVG(v) FROM t WHERE g = 4;
SELECT AVG(v) FROM t WHERE g = 13;
SELECT g, AVG(v) FROM t WHERE g >= 13 GROUP BY g ORDER BY AVG(v), g DESC;
SELECT g, AVG(v) < 0, AVG(v) = 0, AVG(v) IS NULL, NOT AVG(v) FROM t WHERE g >= 13 GROUP BY g;
SELECT AVG(v) FROM t WHERE g = 3;
SELECT AVG(v) FROM t WHERE g = 200;
SELECT AVG(v) FROM t WHERE g = 200 GROUP BY g;
SELECT g, AVG(v) FROM t GROUP BY g HAVING AVG(v) > 1;
SELECT g, AVG(v) FROM t GROUP BY g HAVING AVG(v) >= 1 AND AVG(v) < 2;
SELECT g, AVG(v) FROM t GROUP BY g HAVING AVG(v) = 1;
SELECT g, AVG(v) FROM t GROUP BY g HAVING AVG(v) = 0;
SELECT g, AVG(v) FROM t GROUP BY g HAVING AVG(v) < 0;
SELECT g, AVG(v) FROM t GROUP BY g HAVING AVG(v) IS NULL;
SELECT g, AVG(v) FROM t GROUP BY g ORDER BY AVG(v) DESC, g;
SELECT g, AVG(v) AS a FROM t GROUP BY g ORDER BY a, g DESC;
SELECT g, AVG(v) FROM t GROUP BY g HAVING AVG(v) > 0 ORDER BY 2 DESC, 1 LIMIT 3;
SELECT g, AVG(v), AVG(v) > 1, AVG(v) = 2, AVG(v) IS NOT NULL, NOT AVG(v) FROM t GROUP BY g;
SELECT AVG(v), AVG(v * 100), AVG(v * 1000), AVG(-v) FROM t;
CREATE TABLE big (v INTEGER);
INSERT INTO big VALUES (123456789012), (123456789013), (123456789015), (1);
SELECT AVG(v), SUM(v), AVG(v) > 92592591760 FROM big;
''')

add('having', '''
CREATE TABLE sales (region TEXT, rep TEXT, amount INTEGER);
INSERT INTO sales VALUES ('n', 'a', 10), ('n', 'b', 20), ('s', 'a', 5), ('s', 'c', NULL), ('e', 'a', 7), ('e', 'a', 8), ('e', 'b', 9), (NULL, 'd', 1), ('w', 'e', 100);
SELECT region, COUNT(*) FROM sales GROUP BY region HAVING COUNT(*) > 1;
SELECT region, SUM(amount) FROM sales GROUP BY region HAVING SUM(amount) >= 24;
SELECT region, SUM(amount) FROM sales GROUP BY region HAVING SUM(amount) < 24 OR SUM(amount) IS NULL;
SELECT region FROM sales GROUP BY region HAVING MIN(amount) IS NULL;
SELECT region FROM sales GROUP BY region HAVING region IS NULL OR region > 'n';
SELECT region, rep, COUNT(*) FROM sales GROUP BY region, rep HAVING COUNT(*) = 2 OR rep = 'e';
SELECT rep, COUNT(*) AS n FROM sales GROUP BY rep HAVING COUNT(*) > 1 ORDER BY n DESC, rep;
SELECT region, MAX(amount) FROM sales WHERE amount > 5 GROUP BY region HAVING MAX(amount) < 50 ORDER BY 2 DESC;
SELECT region, COUNT(*) FROM sales GROUP BY region HAVING 1;
SELECT region, COUNT(*) FROM sales GROUP BY region HAVING 0;
SELECT region, COUNT(*) FROM sales GROUP BY region HAVING NULL;
SELECT region, COUNT(*) FROM sales GROUP BY region HAVING COUNT(*) > 1 LIMIT 1 OFFSET 1;
SELECT region FROM sales GROUP BY region HAVING SUM(amount) > 10 ORDER BY COUNT(*) DESC, region DESC;
SELECT rep FROM sales GROUP BY rep HAVING COUNT(*) > 100;
''')

add('errors', '''
SELECT * FROM nosuch;
CREATE TABLE t (a INTEGER, b TEXT);
CREATE TABLE t (a INTEGER);
CREATE TABLE u (a INTEGER, a TEXT);
CREATE TABLE u (a INTEGER, A TEXT);
CREATE TABLE T (q INTEGER);
CREATE TABLE ();
CREATE TABLE v (a INTEGER,);
INSERT INTO t VALUES (1);
INSERT INTO t VALUES (1, 'x', 2);
INSERT INTO t VALUES (1, 'x'), (2);
INSERT INTO t VALUES (a, 'x');
INSERT INTO nosuch VALUES (1, 'x');
SELECT COUNT(*) FROM t;
INSERT INTO t VALUES (1, 'x'), (2, 'y');
SELECT c FROM t;
SELECT t.c FROM t;
SELECT x.a FROM t;
SELECT a FROM t WHERE c = 1;
SELECT a FROM t ORDER BY c;
SELECT a FROM t GROUP BY c;
SELECT a FROM t GROUP BY a HAVING c > 1;
SELECT * FROM t AS x WHERE t.a = 1;
SELECT a FROM t, t;
SELECT a FROM t x, t y;
SELECT x.a FROM t x, t y WHERE b = 'x';
SELECT a FROM t WHERE COUNT(*) > 0;
SELECT COUNT(COUNT(*)) FROM t;
SELECT MAX(SUM(a)) FROM t;
SELECT a FROM t ORDER BY 0;
SELECT a FROM t ORDER BY 2;
SELECT a FROM t ORDER BY COUNT(*);
SELECT;
SELECT a FROM t OFFSET 1;
SELECT a FROM;
SELECT FROM t;
SELECT a, FROM t;
SELECT (a FROM t;
SELECT a) FROM t;
SELECT a FROM t WHERE;
SELECT a FROM t WHERE a = ;
SELECT a FROM t WHERE a == = 1;
SELECT a FROM t ORDER BY;
SELECT a FROM t GROUP BY;
SELECT * FROM t x JOIN t y ON;
SELECT a FROM t WHERE a NOT = 1;
SELECT NOT;
SELECT 1 +;
SELECT select FROM t;
SELECT a FROM t WHERE b LIKE;
SELECT 1;
SELECT a FROM t WHERE a = 1 extra;
SELECT * FROM 1;
SELECT * ;
SELECT *;
UPDATE t SET c = 1;
UPDATE t SET a = c;
UPDATE t SET a = 1 WHERE c = 1;
UPDATE nosuch SET a = 1;
UPDATE t SET a = COUNT(*);
UPDATE t SET a = 1, ;
UPDATE t a = 1;
DELETE FROM t WHERE c = 1;
DELETE FROM nosuch;
DELETE FROM t WHERE COUNT(*) > 0;
DELETE t;
DELETE FROM t WHERE a = 1 AND;
SELECT * FROM t;
INSERT INTO t VALUES (1 'x');
INSERT INTO t VALUES ();
INSERT INTO t VALUES (COUNT(*), 'x');
INSERT INTO t VALUES;
INSERT t VALUES (1, 'x');
SELECT * FROM t;
SELECT 'unterminated FROM t;
SELECT 1;
''')

# Statements the spec rejects but SQLite accepts (unsupported syntax, or
# SQLite extensions); the expected output is declared here by hand.
SPEC_ONLY_ERRORS = '''
CREATE TABLE t (a INTEGER, b TEXT);
INSERT INTO t VALUES (1, 'x'), (2, 'y');
CREATE TABLE v (a REAL);
CREATE TABLE w (a INTEGER PRIMARY KEY);
CREATE TABLE v (a);
SELECT a FROM t x, t x;
SELECT a FROM t GROUP BY a + 1;
SELECT a FROM t HAVING COUNT(*) > 0;
SELECT a FROM t LIMIT -1;
SELECT a FROM t LIMIT 1 OFFSET -1;
SELECT a FROM t LIMIT a;
SELECT LENGTH(b) FROM t;
SELECT * FROM t x JOIN t y;
SELECT * FROM t x, t y, t z;
SELECT * FROM t x JOIN t y ON 1 JOIN t z ON 1;
SELECT a FROM t WHERE a IS 1;
SELECT a FROM t WHERE a IS NOT 1;
SELECT a FROM t WHERE @a = 1;
SELECT a FROM t WHERE a = 1.5;
SELECT a FROM t WHERE a = "x";
SELECT a FROM t WHERE a = $1;
SELECT a, COUNT(*) FROM t;
SELECT b FROM t GROUP BY a;
SELECT a FROM t GROUP BY a ORDER BY b;
SELECT a FROM t GROUP BY a HAVING b = 'x';
SELECT t.* FROM t;
SELECT a FROM t WHERE a IN (1, 2);
SELECT a FROM t WHERE a BETWEEN 1 AND 2;
SELECT DISTINCT a FROM t;
SELECT a || b FROM t;
SELECT a FROM t LIMIT 1, 1;
SELECT a FROM t ORDER BY a NULLS LAST;
SELECT a FROM t WHERE b LIKE 'x' ESCAPE '\\\\';
SELECT a FROM t LEFT JOIN t u ON 1;
SELECT * FROM t LEFT JOIN t u ON 1;
SELECT * FROM t RIGHT JOIN t u ON 1;
SELECT * FROM t FULL OUTER JOIN t u ON 1;
SELECT * FROM t CROSS JOIN t u ON 1;
SELECT * FROM t NATURAL JOIN t u;
SELECT * FROM t x, t y ON 1;
SELECT a AS outer FROM t;
CREATE TABLE lj (left INTEGER);
SELECT 'a' 'b';
SELECT a 'b' FROM t;
CREATE TABLE i (a INT);
CREATE TABLE k (integer INTEGER);
CREATE TABLE k2 (a TEXT, text TEXT);
SELECT a AS text FROM t;
SELECT a FROM t GROUP BY 1;
SELECT a FROM (SELECT a FROM t);
INSERT INTO t (a, b) VALUES (1, 'x');
INSERT INTO t SELECT * FROM t;
DROP TABLE t;
DELETE FROM t WHERE a = 1 LIMIT 1;
UPDATE t SET a = 1 WHERE a = 1 LIMIT 1;
UPDATE t SET (a) = (1);
CREATE INDEX i ON t (a);
BEGIN;
SELECT COUNT(*) FROM t;
'''
add('errors_spec_only', SPEC_ONLY_ERRORS)

add('lexical', """
create table Mixed (Id integer, Name TEXT);
INSERT INTO mixed VALUES (1, 'A'), (2, 'b');
select ID, NAME from MIXED where id = 1;
SeLeCt iD FrOm mIxEd WhErE nAmE = 'b';
SELECT
  id,
  name
FROM
  mixed
WHERE
  id > 0
ORDER BY
  id DESC;
SELECT id FROM mixed WHERE id=1;SELECT id FROM mixed WHERE id=2;
SELECT id,name FROM mixed WHERE(id=1)OR(id=2);
SELECT id FROM mixed WHERE id=1 -- trailing comment
;
-- a comment line; with a semicolon
SELECT id FROM mixed -- comment before clause
WHERE id = 2;
SELECT 'it''s', '', '''', 'a''b''c', ' padded ', 'semi;colon', 'dash--dash', 'x--y';
SELECT '--not a comment', 1 -- but this is; SELECT 2;
;
SELECT 1;;SELECT 2;
;
;
SELECT 1--comment
+2;
SELECT id FROM mixed WHERE name = 'A' ;
	SELECT		id	FROM	mixed	WHERE	id	=	2	;
SELECT id FROM mixed WHERE name='A'AND id=1;
SELECT 1+1,2-1,3*2,8/2,7%4,-1,(1);
SELECT id FROM mixed WHERE id<2;
SELECT id FROM mixed WHERE id>=2;
SELECT id FROM mixed WHERE id<>2;
SELECT id FROM mixed WHERE id!=2;
SELECT 007, 010 + 1, 0;
CREATE TABLE _u (_a INTEGER, b2 TEXT, C_3 INTEGER);
INSERT INTO _u VALUES (1, 'x', 2);
SELECT c_3, B2, _A FROM _U;
SELECT count(*), Count(_a), COUNT(*) FROM _u;
SELECT count (*), COUNT  ( * ), sum ( _a ), MAX -- comment between name and paren
  (c_3) FROM _u;
CREATE TABLE f (count INTEGER, sum INTEGER, avg TEXT, min INTEGER, max INTEGER);
INSERT INTO f VALUES (5, 6, 'x', 7, 8), (1, 2, 'y', NULL, 4);
SELECT count, sum, avg, min, max FROM f ORDER BY count;
SELECT count(*), sum(sum), max(avg), min(count), avg(max), count(min) FROM f;
SELECT count + sum, max - min FROM f WHERE avg LIKE 'x';
SELECT f.count, f.sum FROM f WHERE f.min IS NULL;
SELECT 1 FROM mixed WHERE id = 1 LIMIT 1
""")

add('empty_input', '')

add('comments_only', '''-- nothing but comments and empty statements
;
   ;;
-- SELECT 1;
	;
''')

add('text_values', '''
CREATE TABLE t (id INTEGER, s TEXT);
INSERT INTO t VALUES (1, ''), (2, ' '), (3, 'a'), (4, 'A'), (5, 'Z'), (6, 'z'), (7, '0'), (8, '9'), (9, '~'), (10, 'é'), (11, '中文'), (12, 'abc'), (13, 'ab'), (14, '  lead'), (15, 'trail  '), (16, NULL), (17, 'it''s'), (18, '\U0001F600'), (19, 'ÿ'), (20, 'Zz'), (21, '\uFFE5'), (22, '\uE000'), (23, '\U00010000'), (24, '\uFFFD'), (25, 'a\U0001F600'), (26, 'a\uFFE5');
SELECT id, s FROM t ORDER BY s;
SELECT id FROM t ORDER BY s DESC;
SELECT s FROM t WHERE s = '';
SELECT id FROM t WHERE s > 'a';
SELECT id FROM t WHERE s < 'A';
SELECT id FROM t WHERE s >= 'ab' AND s <= 'abc';
SELECT MIN(s), MAX(s), COUNT(s) FROM t;
SELECT id FROM t WHERE s > '\uFFE5' ORDER BY s;
SELECT id FROM t WHERE s LIKE 'a_' ORDER BY s DESC;
SELECT s, COUNT(*) FROM t WHERE s LIKE '_' GROUP BY s;
SELECT id FROM t WHERE s = '0';
SELECT id, s FROM t WHERE s LIKE 'z%';
SELECT id, s FROM t WHERE s LIKE '%s';
SELECT id FROM t WHERE s LIKE '  %';
SELECT s FROM t WHERE id = 17 OR id = 15 OR id = 1;
SELECT s = 'a', s = 'A', s < 'b' FROM t WHERE id = 4;
UPDATE t SET s = '' WHERE s IS NULL;
SELECT id, s FROM t WHERE s = '';
UPDATE t SET s = NULL WHERE s = '';
SELECT COUNT(*), COUNT(s) FROM t;
''')

add('select_no_from', '''
SELECT 1;
SELECT 1, 2, 3;
SELECT 'hello', NULL, -0, 0;
SELECT 1 AS x, 2 AS y;
SELECT (1 + 2) * (3 + 4), 2 * 3 + 4 * 5, 1 - 2 - 3 - 4, 2 * 2 * 2 * 2;
SELECT 1 < 2 AND 2 < 3, 1 < 2 OR NULL, NOT 1 < 2;
SELECT 'x' LIKE '%', NULL LIKE '%', '%' LIKE '\\%', 'a' NOT LIKE 'b';
SELECT NULL IS NULL AND 1, 1 IS NULL OR 1;
SELECT ((((1))));
SELECT -(-(-(1)));
SELECT 1000000 * 1000000, 1000000000 * 1000000000, -9223372036854775807;
SELECT COUNT(*);
SELECT SUM(1), MIN(2), AVG(3), COUNT(NULL), MAX('a'), COUNT(*) + 1;
SELECT 1 WHERE 0;
SELECT 1 WHERE 1 = 1;
SELECT 3 WHERE NULL;
SELECT 2 ORDER BY 1 LIMIT 1 OFFSET 1;
SELECT 4 LIMIT 0;
SELECT 5, 6 ORDER BY 2 DESC LIMIT 1;
SELECT COUNT(*) WHERE 0;
''')

add('column_alias_and_star', '''
CREATE TABLE a (x INTEGER, y INTEGER);
CREATE TABLE b (y INTEGER, z TEXT);
INSERT INTO a VALUES (1, 10), (2, 20), (3, 30);
INSERT INTO b VALUES (10, 'ten'), (30, 'thirty'), (40, 'forty');
SELECT * FROM a;
SELECT *, x FROM a;
SELECT x, * FROM a;
SELECT *, * FROM a WHERE x = 2;
SELECT * FROM a, b WHERE a.y = b.y;
SELECT * FROM a INNER JOIN b ON a.y = b.y ORDER BY z;
SELECT x AS a, y AS b FROM a ORDER BY b DESC;
SELECT x AS y, y AS x FROM a ORDER BY x;
SELECT x AS y, y AS x FROM a ORDER BY y DESC;
SELECT x + y AS total, x AS x FROM a ORDER BY total DESC;
SELECT a.x AS ax, b.z AS bz FROM a, b WHERE a.y = b.y ORDER BY bz;
SELECT x AS n FROM a ORDER BY n DESC, x;
SELECT x AS n, y AS n FROM a ORDER BY n DESC;
SELECT COUNT(*) AS c, x FROM a GROUP BY x ORDER BY c, x DESC;
SELECT a.y, z FROM a, b WHERE a.y = b.y;
SELECT y FROM a, b WHERE x = 1;
SELECT z, y FROM b, a WHERE a.y = b.y;
SELECT x AS star FROM a WHERE x > 1;
SELECT *, x FROM a ORDER BY 2 DESC;
SELECT *, x + 100 FROM a ORDER BY 3 DESC, 1;
SELECT * FROM a, b WHERE a.y = b.y ORDER BY 4 DESC;
SELECT *, * FROM a ORDER BY 4 DESC, 1;
''')

add('combined_inventory', '''
CREATE TABLE items (sku TEXT, cat TEXT, price INTEGER, stock INTEGER);
CREATE TABLE cats (cat TEXT, taxpct INTEGER, mgr TEXT);
INSERT INTO items VALUES ('A1', 'tools', 1500, 3), ('A2', 'tools', 250, 0), ('B1', 'toys', 999, 12), ('B2', 'toys', 1999, 1), ('B3', 'toys', NULL, 5), ('C1', 'food', 5, 200), ('C2', 'food', 12, 150), ('D1', NULL, 100, 1), ('E1', 'garden', 4500, 2);
INSERT INTO cats VALUES ('tools', 20, 'ann'), ('toys', 5, 'bob'), ('food', 0, 'ann'), ('misc', 10, NULL);
SELECT c.mgr, COUNT(*), SUM(i.price * i.stock) FROM items i JOIN cats c ON i.cat = c.cat GROUP BY c.mgr ORDER BY 3 DESC;
SELECT i.sku, i.price + i.price * c.taxpct / 100 AS gross FROM items i, cats c WHERE i.cat = c.cat AND i.stock > 0 ORDER BY gross DESC, i.sku LIMIT 3;
SELECT cat, COUNT(*) AS n, MIN(price), MAX(price), AVG(price) FROM items WHERE price IS NOT NULL GROUP BY cat HAVING COUNT(*) >= 2 ORDER BY AVG(price) DESC;
SELECT sku FROM items WHERE cat LIKE 't%' AND (price < 1000 OR stock = 0) ORDER BY price DESC;
UPDATE items SET price = price * 9 / 10 WHERE cat = 'toys' AND price > 500;
SELECT sku, price FROM items WHERE cat = 'toys' ORDER BY sku;
DELETE FROM items WHERE stock = 0 OR price IS NULL;
SELECT COUNT(*), SUM(stock) FROM items;
SELECT c.cat, c.mgr FROM cats c WHERE NOT c.cat LIKE '%o%' OR c.mgr IS NULL ORDER BY c.cat;
SELECT i.cat, c.taxpct, COUNT(i.sku) FROM items i INNER JOIN cats c ON c.cat = i.cat WHERE c.taxpct > 0 GROUP BY i.cat, c.taxpct;
SELECT a.sku, b.sku FROM items a, items b WHERE a.cat = b.cat AND a.sku < b.sku AND a.price > b.price ORDER BY a.sku, b.sku;
SELECT sku, stock FROM items ORDER BY stock DESC, sku LIMIT 2 OFFSET 1;
SELECT COUNT(*) FROM items i, cats c WHERE i.cat = c.cat AND i.price * (100 + c.taxpct) % 100 = 0;
SELECT cat, SUM(price * stock) FROM items GROUP BY cat HAVING SUM(price * stock) > 2000 ORDER BY cat DESC;
INSERT INTO items VALUES ('F1', 'misc', 1, 1);
SELECT c.cat, COUNT(*) FROM cats c JOIN items i ON i.cat = c.cat GROUP BY c.cat ORDER BY c.cat;
SELECT c.mgr, i.sku FROM cats c INNER JOIN items i ON c.cat = i.cat WHERE c.mgr IS NULL OR i.stock > 100 ORDER BY 1 DESC, 2;
''')

add('combined_library', '''
CREATE TABLE books (id INTEGER, title TEXT, author INTEGER, year INTEGER, pages INTEGER);
CREATE TABLE authors (id INTEGER, name TEXT, born INTEGER);
INSERT INTO authors VALUES (1, 'Orwell', 1903), (2, 'Austen', 1775), (3, 'Tolkien', 1892), (4, 'Anonymous', NULL);
INSERT INTO books VALUES (1, '1984', 1, 1949, 328), (2, 'Animal Farm', 1, 1945, 112), (3, 'Emma', 2, 1815, 474), (4, 'Persuasion', 2, 1817, 249), (5, 'The Hobbit', 3, 1937, 310), (6, 'Beowulf', 4, NULL, 213), (7, 'Untitled', NULL, 2001, NULL), (8, 'Pride and Prejudice', 2, 1813, 432);
SELECT a.name, COUNT(*) AS n, SUM(b.pages) AS p FROM books b JOIN authors a ON b.author = a.id GROUP BY a.name ORDER BY p DESC;
SELECT b.title, a.name, b.year - a.born AS age FROM books b JOIN authors a ON b.author = a.id WHERE b.year - a.born < 40 ORDER BY age, b.title;
SELECT title FROM books WHERE title LIKE '%e%' AND title NOT LIKE 'P%' ORDER BY pages DESC;
SELECT author, MIN(year), MAX(year), MAX(year) - MIN(year) FROM books GROUP BY author HAVING COUNT(*) > 1 ORDER BY author DESC;
SELECT a.name FROM authors a JOIN books b ON a.id = b.author WHERE b.pages > 300 GROUP BY a.name HAVING COUNT(*) >= 2;
SELECT title, pages FROM books WHERE pages IS NOT NULL ORDER BY pages % 100, title LIMIT 4 OFFSET 2;
SELECT year / 100 + 1 AS century, COUNT(*), AVG(pages) FROM books WHERE year IS NOT NULL GROUP BY year ORDER BY century, year;
SELECT COUNT(*), COUNT(year), COUNT(pages), SUM(pages), AVG(pages), MIN(title), MAX(title) FROM books;
UPDATE books SET year = 1000, pages = pages + 10 WHERE year IS NULL;
SELECT id, year, pages FROM books WHERE id = 6 OR id = 7;
DELETE FROM authors WHERE born IS NULL;
SELECT b.title FROM books b, authors a WHERE b.author = a.id ORDER BY a.born DESC, b.year;
SELECT b1.title, b2.title FROM books b1 JOIN books b2 ON b1.author = b2.author AND b1.year < b2.year ORDER BY b1.title, b2.title;
SELECT a.name, b.title FROM authors a, books b WHERE a.born < 1800 AND b.year > 1940 ORDER BY 1, 2;
SELECT name FROM authors WHERE id NOT LIKE '%' OR name LIKE '%en';
''')

add('combined_scores', '''
CREATE TABLE players (pid INTEGER, name TEXT, team TEXT);
CREATE TABLE games (gid INTEGER, pid INTEGER, pts INTEGER, week INTEGER);
INSERT INTO players VALUES (1, 'amy', 'red'), (2, 'ben', 'red'), (3, 'cal', 'blue'), (4, 'dan', 'blue'), (5, 'eli', NULL);
INSERT INTO games VALUES (1, 1, 10, 1), (2, 2, 7, 1), (3, 3, 12, 1), (4, 4, NULL, 1), (5, 1, 3, 2), (6, 2, 15, 2), (7, 3, 9, 2), (8, 5, 30, 2), (9, 1, 20, 3), (10, 9, 5, 3);
SELECT p.team, SUM(g.pts), AVG(g.pts), COUNT(g.pts), COUNT(*) FROM players p JOIN games g ON p.pid = g.pid GROUP BY p.team ORDER BY SUM(g.pts) DESC;
SELECT p.name, SUM(g.pts) AS total FROM players p JOIN games g ON p.pid = g.pid GROUP BY p.name HAVING SUM(g.pts) > 20 ORDER BY total DESC, p.name;
SELECT g.week, MAX(g.pts), MIN(g.pts) FROM games g GROUP BY g.week HAVING MIN(g.pts) < 5 ORDER BY g.week DESC;
SELECT name FROM players WHERE pid IN_LIST;
SELECT p.name, g.pts FROM players p, games g WHERE p.pid = g.pid AND g.week = 2 AND g.pts >= 9 ORDER BY g.pts;
SELECT p.name, COUNT(*) FROM players p, games g WHERE p.pid = g.pid AND p.team = 'red' GROUP BY p.name;
SELECT p1.name, p2.name FROM players p1 JOIN players p2 ON p1.team = p2.team AND p1.pid < p2.pid;
SELECT week, COUNT(*), SUM(pts) FROM games WHERE pid <= 3 GROUP BY week;
UPDATE games SET pts = 0 WHERE pts IS NULL;
UPDATE games SET pts = pts * 2 WHERE week = 3;
DELETE FROM games WHERE pid = 5;
SELECT p.name, SUM(g.pts) FROM players p JOIN games g ON p.pid = g.pid GROUP BY p.name ORDER BY 2 DESC LIMIT 2;
SELECT COUNT(*) FROM players p, games g WHERE p.pid = g.pid;
SELECT COUNT(*) FROM players p, games g WHERE p.pid != g.pid;
SELECT COUNT(*) FROM players p, games g WHERE p.pid <> g.pid AND p.team IS NOT NULL;
SELECT g.gid FROM games g JOIN players p ON g.pid = p.pid WHERE p.team IS NULL;
SELECT team, COUNT(*) FROM players GROUP BY team HAVING COUNT(*) = 1 OR team IS NULL;
''')

# ---------------------------------------------------------------------------
# Seeded random workloads
# ---------------------------------------------------------------------------

NAMES = ['alice', 'bob', 'carol', 'dave', 'erin', 'frank', 'grace', 'heidi', 'ivan', 'judy',
         'mallory', 'oscar', 'peggy', 'trent', 'victor', 'wendy', 'Al', 'Bea', 'x', '']
DEPTS = ['eng', 'ops', 'sales', 'hr', 'legal']
CITIES = ['austin', 'boston', 'chicago', 'denver', 'erie', 'fargo', 'gary', 'houston', 'irvine', 'juneau']


def lit(v):
    if v is None:
        return 'NULL'
    if isinstance(v, str):
        return "'" + v.replace("'", "''") + "'"
    return str(v)


def random_workload(seed, n_emp, n_stmts):
    rnd = random.Random(seed)
    out = ['CREATE TABLE emp (id INTEGER, name TEXT, dept TEXT, salary INTEGER, age INTEGER);',
           'CREATE TABLE dept (dname TEXT, floor INTEGER, budget INTEGER);']
    depts = DEPTS[:rnd.randint(3, 5)]
    for d in depts:
        if rnd.random() < 0.85:
            out.append('INSERT INTO dept VALUES (%s, %d, %s);' % (lit(d), rnd.randint(1, 4), lit(rnd.choice([None, 100, 250, 500, 1000]))))
    out.append("INSERT INTO dept VALUES ('archive', NULL, 0);")
    next_id = [1]

    def emp_row():
        i = next_id[0]
        next_id[0] += 1
        return (i, rnd.choice(NAMES) if rnd.random() < 0.95 else None,
                rnd.choice(depts) if rnd.random() < 0.9 else None,
                rnd.randint(10, 90) * 100 if rnd.random() < 0.9 else None,
                rnd.randint(20, 60) if rnd.random() < 0.9 else None)

    rows = [emp_row() for _ in range(n_emp)]
    for i in range(0, len(rows), 7):
        out.append('INSERT INTO emp VALUES ' + ', '.join('(' + ', '.join(lit(v) for v in r) + ')' for r in rows[i:i + 7]) + ';')

    def k():
        return rnd.randint(1000, 9000)

    def d():
        return lit(rnd.choice(depts + [None]))

    def pat():
        return lit(rnd.choice(['a%', '%e', '%a%', '_o%', 'A%', '%Y', '', '%', '_', '____', 'x', 'al%']))

    queries = [
        lambda: 'SELECT * FROM emp WHERE salary > %d ORDER BY id;' % k(),
        lambda: 'SELECT name, salary FROM emp WHERE dept = %s OR age < %d ORDER BY salary DESC, id;' % (d(), rnd.randint(20, 60)),
        lambda: 'SELECT id, name FROM emp WHERE name LIKE %s ORDER BY name, id;' % pat(),
        lambda: 'SELECT id, name FROM emp WHERE name NOT LIKE %s AND dept IS NOT NULL ORDER BY id DESC LIMIT %d;' % (pat(), rnd.randint(1, 8)),
        lambda: 'SELECT dept, COUNT(*), SUM(salary), MIN(age), MAX(age), AVG(salary) FROM emp GROUP BY dept;',
        lambda: 'SELECT dept, COUNT(*) AS n FROM emp WHERE age IS NOT NULL GROUP BY dept HAVING COUNT(*) > %d ORDER BY n DESC, dept;' % rnd.randint(0, 4),
        lambda: 'SELECT e.name, d.floor FROM emp e, dept d WHERE e.dept = d.dname AND d.floor > %d ORDER BY e.id;' % rnd.randint(0, 3),
        lambda: 'SELECT e.name, d.budget FROM emp AS e INNER JOIN dept AS d ON e.dept = d.dname ORDER BY d.budget DESC, e.name, e.id LIMIT %d OFFSET %d;' % (rnd.randint(1, 10), rnd.randint(0, 5)),
        lambda: 'SELECT d.dname, COUNT(*), AVG(e.salary) FROM dept d INNER JOIN emp e ON d.dname = e.dept GROUP BY d.dname HAVING AVG(e.salary) > %d ORDER BY 3 DESC, 1;' % k(),
        lambda: 'SELECT a.name, b.name FROM emp a, emp b WHERE a.dept = b.dept AND a.id < b.id AND a.salary > b.salary ORDER BY a.id, b.id;',
        lambda: 'SELECT COUNT(*), SUM(salary), AVG(age), MIN(name), MAX(name) FROM emp WHERE dept IS NULL;',
        lambda: 'SELECT COUNT(*), SUM(salary), AVG(age), MIN(salary), MAX(age) FROM emp WHERE dept = %s;' % d(),
        lambda: 'SELECT name, salary * 2 - age AS s FROM emp WHERE salary %% %d = 0 ORDER BY s, id;' % rnd.choice([300, 700, 1100, 400]),
        lambda: 'SELECT id, name FROM emp WHERE NOT (age > %d AND dept = %s) ORDER BY id LIMIT %d;' % (rnd.randint(20, 60), d(), rnd.randint(1, 12)),
        lambda: 'SELECT * FROM emp ORDER BY dept, salary DESC, id;',
        lambda: 'SELECT salary, COUNT(*) FROM emp GROUP BY salary HAVING COUNT(*) >= 2;',
        lambda: 'SELECT * FROM emp WHERE age IS NULL;',
        lambda: 'SELECT name, dept FROM emp ORDER BY dept;',
        lambda: 'SELECT id FROM emp ORDER BY age DESC;',
        lambda: 'SELECT dept, age, COUNT(*) FROM emp GROUP BY dept, age HAVING age IS NULL OR COUNT(*) > 1;',
        lambda: 'SELECT age / 10, COUNT(*), AVG(salary) FROM emp WHERE age IS NOT NULL GROUP BY age ORDER BY 1, 2 DESC, age;',
        lambda: 'SELECT e.id, d.floor * 1000 + e.salary FROM emp e JOIN dept d ON e.dept = d.dname WHERE e.salary IS NOT NULL ORDER BY 2 DESC, 1 LIMIT 5;',
        lambda: 'SELECT e.name FROM emp e JOIN dept d ON e.dept = d.dname AND e.salary > d.budget * %d ORDER BY e.id;' % rnd.randint(1, 10),
        lambda: 'SELECT a.id, b.id FROM emp a JOIN emp b ON a.age = b.age WHERE a.id < b.id ORDER BY a.id, b.id;',
        lambda: 'SELECT dept, MIN(name), MAX(name), COUNT(name) FROM emp GROUP BY dept ORDER BY dept DESC;',
        lambda: 'SELECT id, age, age IS NULL, age > %d, NOT age > %d FROM emp WHERE id %% 3 = 0 ORDER BY id;' % (rnd.randint(20, 60), rnd.randint(20, 60)),
        lambda: 'SELECT name, COUNT(*) FROM emp WHERE name LIKE %s GROUP BY name ORDER BY 2 DESC, 1 LIMIT 3;' % pat(),
        lambda: 'SELECT d.dname, COUNT(*) FROM dept d, emp e WHERE d.dname = e.dept OR d.floor = e.age / 10 GROUP BY d.dname;',
        lambda: 'SELECT SUM(e.salary) / COUNT(*), AVG(e.salary) FROM emp e, dept d WHERE e.dept = d.dname;',
    ]
    mutations = [
        lambda: 'UPDATE emp SET salary = salary + %d WHERE dept = %s;' % (rnd.randint(-500, 500), d()),
        lambda: 'UPDATE emp SET age = NULL WHERE id %% %d = 0;' % rnd.randint(5, 11),
        lambda: 'UPDATE emp SET dept = %s, age = age + 1 WHERE salary < %d;' % (d(), k()),
        lambda: 'UPDATE emp SET name = %s WHERE name IS NULL OR name = %s;' % (lit(rnd.choice(NAMES)), lit(rnd.choice(NAMES))),
        lambda: 'DELETE FROM emp WHERE salary < %d;' % rnd.randint(1000, 2500),
        lambda: 'DELETE FROM emp WHERE id = %d;' % rnd.randint(1, n_emp),
        lambda: 'INSERT INTO emp VALUES ' + ', '.join('(' + ', '.join(lit(v) for v in emp_row()) + ')' for _ in range(rnd.randint(1, 3))) + ';',
        lambda: 'UPDATE dept SET floor = floor + 1 WHERE budget IS NULL;',
    ]
    errors = [
        lambda: 'SELECT nosuch FROM emp;',
        lambda: 'SELECT * FROM emp WHERE;',
        lambda: 'INSERT INTO emp VALUES (1);',
        lambda: 'SELECT COUNT(*) FROM emp WHERE nosuch = 1;',
        lambda: 'SELECT dname FROM emp e, dept d WHERE name = d;',
        lambda: 'UPDATE emp SET nosuch = 1;',
    ]
    for _ in range(n_stmts):
        r = rnd.random()
        if r < 0.7:
            out.append(rnd.choice(queries)())
        elif r < 0.93:
            out.append(rnd.choice(mutations)())
        else:
            out.append(rnd.choice(errors)())
    out.append('SELECT COUNT(*) FROM emp;')
    return '\n'.join(out) + '\n'


add('random_small_1', random_workload(101, 12, 30))
add('random_small_2', random_workload(202, 20, 40))
add('random_medium_1', random_workload(303, 150, 60))
add('random_medium_2', random_workload(404, 300, 80))
add('random_medium_3', random_workload(505, 500, 80))


# ---------------------------------------------------------------------------
# Performance workloads: 2 000 users, 20 000 orders
# ---------------------------------------------------------------------------

def perf_dataset(seed, n_users=2000, n_orders=20000):
    rnd = random.Random(seed)
    out = ['CREATE TABLE users (id INTEGER, name TEXT, city TEXT, age INTEGER);',
           'CREATE TABLE orders (id INTEGER, user_id INTEGER, amount INTEGER, status TEXT);']
    users = [(i, rnd.choice(NAMES[:16]) + str(rnd.randint(1, 999)),
              rnd.choice(CITIES) if rnd.random() < 0.97 else None,
              rnd.randint(18, 80) if rnd.random() < 0.95 else None) for i in range(1, n_users + 1)]
    orders = [(i, rnd.randint(1, n_users + 50), rnd.randint(1, 5000) if rnd.random() < 0.97 else None,
               rnd.choice(['new', 'paid', 'shipped', 'done', 'cancelled'])) for i in range(1, n_orders + 1)]
    for i in range(0, n_users, 500):
        out.append('INSERT INTO users VALUES ' + ', '.join('(' + ', '.join(lit(v) for v in r) + ')' for r in users[i:i + 500]) + ';')
    for i in range(0, n_orders, 500):
        out.append('INSERT INTO orders VALUES ' + ', '.join('(' + ', '.join(lit(v) for v in r) + ')' for r in orders[i:i + 500]) + ';')
    return out


add('perf_scan_filter', '\n'.join(perf_dataset(1) + [
    'SELECT COUNT(*), SUM(amount), MIN(amount), MAX(amount), AVG(amount) FROM orders;',
    "SELECT id, user_id, amount FROM orders WHERE status = 'paid' AND amount > 4900 ORDER BY amount DESC, id LIMIT 30;",
    "SELECT id, name FROM users WHERE name LIKE 'al%' AND age < 30 ORDER BY id;",
    "SELECT COUNT(*) FROM orders WHERE amount % 7 = 0 AND status NOT LIKE '%e%';",
    'SELECT id FROM orders WHERE amount IS NULL ORDER BY id DESC LIMIT 20;',
    "UPDATE orders SET status = 'refund', amount = -amount WHERE status = 'cancelled' AND amount > 4000;",
    "SELECT COUNT(*), SUM(amount) FROM orders WHERE status = 'refund';",
    'DELETE FROM orders WHERE amount < 100 OR amount IS NULL;',
    'SELECT COUNT(*), SUM(amount) FROM orders;',
    'SELECT status, COUNT(*), SUM(amount), AVG(amount) FROM orders GROUP BY status ORDER BY status;',
    'SELECT id, amount FROM orders ORDER BY amount, id LIMIT 25 OFFSET 10000;',
]) + '\n')

add('perf_join_group', '\n'.join(perf_dataset(2) + [
    'SELECT u.city, COUNT(*), SUM(o.amount), AVG(o.amount), MIN(o.amount), MAX(o.amount) FROM users u JOIN orders o ON u.id = o.user_id GROUP BY u.city ORDER BY 3 DESC;',
    "SELECT u.city, o.status, COUNT(*) FROM users u, orders o WHERE u.id = o.user_id AND u.age > 40 GROUP BY u.city, o.status HAVING COUNT(*) > 250 ORDER BY u.city, o.status;",
    'SELECT u.name, SUM(o.amount) AS total FROM orders o INNER JOIN users u ON o.user_id = u.id GROUP BY u.name HAVING SUM(o.amount) > 40000 ORDER BY total DESC, u.name LIMIT 15;',
    "SELECT u.id, u.name, o.amount FROM users u JOIN orders o ON u.id = o.user_id WHERE o.status = 'new' AND o.amount > 4950 ORDER BY o.amount DESC, u.id, o.id;",
    'SELECT COUNT(*) FROM orders o JOIN users u ON o.user_id = u.id WHERE u.city IS NULL;',
    'SELECT o.user_id, COUNT(*), AVG(o.amount) FROM orders o GROUP BY o.user_id HAVING COUNT(*) >= 18 ORDER BY 2 DESC, 1;',
    'SELECT u.age, COUNT(*), AVG(o.amount) FROM users u JOIN orders o ON u.id = o.user_id WHERE u.age IS NOT NULL GROUP BY u.age ORDER BY AVG(o.amount) DESC, u.age LIMIT 10;',
]) + '\n')

add('perf_self_join', '\n'.join(perf_dataset(3) + [
    'SELECT a.city, COUNT(*) FROM users a JOIN users b ON a.city = b.city WHERE a.id < b.id AND a.age = b.age GROUP BY a.city ORDER BY a.city;',
    'SELECT a.id, b.id FROM users a, users b WHERE a.city = b.city AND a.age = b.age AND a.name = b.name AND a.id < b.id ORDER BY a.id, b.id;',
    "SELECT COUNT(*) FROM users a JOIN users b ON a.age = b.age WHERE a.city != b.city AND a.name LIKE 'j%' AND b.name LIKE 'w%';",
    'SELECT a.age, COUNT(*), MIN(b.id) FROM users a JOIN users b ON a.age + 1 = b.age GROUP BY a.age HAVING COUNT(*) > 800 ORDER BY 2 DESC, 1;',
    'SELECT o.id FROM orders o JOIN orders p ON o.amount = p.amount WHERE o.id < p.id AND o.user_id = p.user_id ORDER BY o.id LIMIT 40;',
    'SELECT COUNT(*) FROM orders o JOIN users u ON o.user_id = u.id AND o.amount > u.age * 60;',
]) + '\n')

add('perf_order_mutate', '\n'.join(perf_dataset(4) + [
    'SELECT id, user_id, amount, status FROM orders ORDER BY status DESC, amount, id;',
    'UPDATE orders SET amount = amount * 2 WHERE user_id % 5 = 0;',
    'UPDATE orders SET status = NULL WHERE amount > 9000;',
    'DELETE FROM orders WHERE user_id > 2000;',
    "DELETE FROM users WHERE age IS NULL OR city = 'gary';",
    'SELECT COUNT(*), SUM(amount), AVG(amount) FROM orders;',
    'SELECT status, COUNT(*), AVG(amount) FROM orders GROUP BY status;',
    'SELECT u.city, COUNT(*), AVG(o.amount) AS a FROM users u JOIN orders o ON u.id = o.user_id GROUP BY u.city HAVING AVG(o.amount) > 2500 ORDER BY a DESC;',
    'SELECT id FROM orders WHERE status IS NULL ORDER BY amount DESC, id LIMIT 50;',
    'SELECT amount, COUNT(*) FROM orders GROUP BY amount HAVING COUNT(*) >= 14 ORDER BY 2 DESC, 1;',
    'SELECT u.name, u.city FROM users u ORDER BY u.city DESC, u.name, u.id LIMIT 100 OFFSET 1900;',
]) + '\n')


# ---------------------------------------------------------------------------
# Write, run the reference, cross-check with SQLite
# ---------------------------------------------------------------------------

def main():
    os.makedirs(TESTS, exist_ok=True)
    names = set()
    total = 0
    for n, (name, text) in enumerate(cases, 1):
        base = '%03d_%s' % (n, name)
        names.add(base)
        in_path = os.path.join(TESTS, base + '.in')
        out_path = os.path.join(TESTS, base + '.out')
        with open(in_path, 'w', encoding='utf-8', newline='\n') as f:
            f.write(text)
        proc = subprocess.run([sys.executable, REF], input=text.encode('utf-8'), capture_output=True, timeout=600)
        if proc.returncode != 0:
            print('reference failed on', base)
            print(proc.stderr.decode())
            sys.exit(1)
        actual = proc.stdout.decode('utf-8').split('\n')
        if actual and actual[-1] == '':
            actual.pop()
        if name == 'errors_spec_only':
            n_stmts = len(ref.split_statements(ref.tokenize(text)))
            expected = ['error'] * (n_stmts - 3) + ['2', '-- 1 rows']
        else:
            expected = oracle(text)
        if actual != expected:
            print('ORACLE MISMATCH in', base)
            for i, (a, e) in enumerate(zip(actual, expected)):
                if a != e:
                    print('  line %d\n    ref:    %r\n    sqlite: %r' % (i + 1, a, e))
                    break
            else:
                print('  lengths differ: ref %d, sqlite %d' % (len(actual), len(expected)))
            sys.exit(1)
        with open(out_path, 'wb') as f:
            f.write(proc.stdout)
        total += len(text)
        n_err = sum(1 for l in expected if l == 'error')
        print('%-32s %8d bytes in, %6d lines out, %d errors' % (base, len(text), len(expected), n_err))
    for f in os.listdir(TESTS):
        stem = f.rsplit('.', 1)[0]
        if stem not in names and (f.endswith('.in') or f.endswith('.out')):
            os.remove(os.path.join(TESTS, f))
    print('%d tests, %.1f MB of input, all cross-checked against sqlite %s' % (len(cases), total / 1e6, sqlite3.sqlite_version))


if __name__ == '__main__':
    main()
