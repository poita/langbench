#!/bin/sh
# Regenerates the fixture databases used by the tests. Needs the sqlite3 shell;
# the committed .sqlite files are the source of truth, so this is only needed
# when changing the fixtures.
set -e
cd "$(dirname "$0")"
rm -f mini.sqlite big.sqlite

sqlite3 mini.sqlite <<'SQL'
PRAGMA page_size=4096;
CREATE TABLE people(
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    age INTEGER,
    height REAL,
    photo BLOB);
INSERT INTO people VALUES
    (1,'Ada',36,1.65,x'000102'),
    (2,'Grace',45,1.7,NULL),
    (3,'Alan',NULL,1.8,x''),
    (6,'',0,0.0,x'7f');
CREATE INDEX people_age ON people(age);
CREATE TABLE kv(k INT PRIMARY KEY, v);
INSERT INTO kv VALUES (10,'ten'),(2,'two');
CREATE TABLE seq(id INTEGER PRIMARY KEY AUTOINCREMENT, note TEXT);
INSERT INTO seq(note) VALUES ('a'),('b');
CREATE VIEW adults AS SELECT name FROM people WHERE age >= 18;
CREATE TRIGGER people_t AFTER INSERT ON people BEGIN SELECT 1; END;
SQL

sqlite3 big.sqlite <<'SQL'
PRAGMA page_size=512;
CREATE TABLE items(
    n INTEGER PRIMARY KEY,
    grp INTEGER,
    label TEXT,
    payload BLOB,
    score REAL);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i < 3000)
INSERT INTO items SELECT i, i % 7, 'label-' || i,
    CASE WHEN i % 100 = 0 THEN randomblob(2000) ELSE zeroblob(i % 40) END,
    i / 4.0 FROM c;
INSERT INTO items VALUES (-5, 3, 'neg', NULL, 0.0), (-9000000000, 3, 'neg-big', NULL, 1.5);
CREATE INDEX items_grp ON items(grp);
CREATE INDEX items_label ON items(label);
CREATE INDEX items_two ON items(grp, label);
SQL
