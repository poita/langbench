(ns sqlitefile.ddl-test
  (:require [clojure.test :refer [deftest is testing are]]
            [sqlitefile.ddl :as ddl]))

(defn- table [sql] (ddl/parse-create-table sql))
(defn- names [t] (mapv :name (:columns t)))

(deftest column-names-and-types
  (let [t (table "CREATE TABLE IF NOT EXISTS main.\"my t\"(
                    a INTEGER NOT NULL DEFAULT 'x,y' -- comment, with comma
                    , `b c` VARCHAR(10, 2), [d] /* c */ , e NUMERIC(10,2) CHECK (e > 0))")]
    (is (= ["a" "b c" "d" "e"] (names t)))
    (is (= ["INTEGER" "VARCHAR ( 10 , 2 )" "" "NUMERIC ( 10 , 2 )"] (mapv :type (:columns t))))
    (is (= [:integer :text :blob :numeric] (mapv :affinity (:columns t))))))

(deftest rowid-alias-forms
  (are [sql alias] (= alias (:rowid-alias (table sql)))
    "CREATE TABLE t(id INTEGER PRIMARY KEY, x)" 0
    "CREATE TABLE t(x, id integer primary key autoincrement)" 1
    "CREATE TABLE t(id INTEGER PRIMARY KEY ASC, x)" 0
    "CREATE TABLE t(id INTEGER PRIMARY KEY DESC, x)" nil
    "CREATE TABLE t(id INTEGER, x, PRIMARY KEY(id DESC))" 0
    "CREATE TABLE t(id INTEGER NOT NULL, CONSTRAINT pk PRIMARY KEY ([id]))" 0
    "CREATE TABLE t(code INT PRIMARY KEY, x)" nil
    "CREATE TABLE t(a INTEGER, b INTEGER, PRIMARY KEY(a, b))" nil
    "CREATE TABLE t(id INTEGER(4) PRIMARY KEY)" nil
    "CREATE TABLE t(id BIGINT PRIMARY KEY)" nil
    "CREATE TABLE t(id INTEGER CHECK (id > 0) PRIMARY KEY)" 0
    "CREATE TABLE t(id INTEGER, y TEXT CHECK (y <> 'PRIMARY KEY'))" nil))

(deftest table-constraints-are-not-columns
  (is (= ["a" "b"]
         (names (table "CREATE TABLE t(a, b, UNIQUE(a), CHECK(a<b), FOREIGN KEY(a) REFERENCES u(x))")))))

(deftest create-index
  (is (= {:table "people" :columns ["age"]}
         (ddl/parse-create-index "CREATE INDEX people_age ON people(age)")))
  (is (= {:table "t" :columns ["a" "b c"]}
         (ddl/parse-create-index "CREATE UNIQUE INDEX IF NOT EXISTS main.i ON \"t\" (a COLLATE BINARY ASC, [b c] DESC)"))))

(deftest rejects-non-tables
  (is (thrown? clojure.lang.ExceptionInfo (table "CREATE VIEW v AS SELECT 1"))))
