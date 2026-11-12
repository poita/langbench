(ns sqlitefile.core-test
  (:require [clojure.test :refer [deftest is testing]]
            [sqlitefile.btree :as btree]
            [sqlitefile.core :as sf]
            [sqlitefile.fixture :as fx]
            [sqlitefile.pager :as pager]))

(def db (sf/from-bytes (fx/sample-db)))

(defn- q [line] (sf/query db line))
(defn- error? [line]
  (try (sf/query db line) false
       (catch clojure.lang.ExceptionInfo _ true)))

(deftest schema-introspection
  (is (= ["blobs" "people"] (sf/tables db)))
  (is (= ["id" "name" "age" "score"] (sf/columns db "PEOPLE")))
  (is (= nil (sf/columns db "nope")))
  (is (= ["CREATE TABLE people(id INTEGER PRIMARY KEY, name TEXT, age INTEGER, score REAL)"
          "CREATE INDEX people_age ON people(age)"]
         (sf/schema-sql db "People")))
  (is (= "blobs\npeople\n" (q ".tables")))
  (is (= "" (q ".schema people_age")))
  (is (= "" (q ".schema nothing"))))

(deftest counting-through-interior-pages
  (is (= 5 (sf/count-rows db "people")))
  (is (= "5\n" (q "COUNT people")))
  (is (= "1\n" (q "COUNT blobs"))))

(deftest full-scan
  (is (= "1\tAda\t36\t1.0\n2\tGrace\t45\t1.7\n3\tAlan\tNULL\t1.8\n4\tBob\t45\tNULL\n5\tCy\t36\t2.5\n"
         (q "SELECT * FROM people")))
  (is (= [[1 "Ada"] [3 "Alan"]]
         (sf/select db "people" {:columns ["rowid" "name"] :where [["name" :< "B"]]}))))

(deftest where-order-limit
  (is (= "Bob\nGrace\n" (q "SELECT name FROM people WHERE age = 45 ORDER BY rowid DESC LIMIT 2")))
  (is (= "Alan\n" (q "SELECT name FROM people WHERE age IS NULL")))
  (is (= "Ada\nGrace\nBob\nCy\n" (q "SELECT name FROM people WHERE age > 0")))
  (testing "NULLs sort first ascending, last descending; ties by ascending rowid"
    (is (= "Alan\nAda\nCy\nGrace\nBob\n" (q "SELECT name FROM people ORDER BY age")))
    (is (= "Grace\nBob\nAda\nCy\nAlan\n" (q "SELECT name FROM people ORDER BY age DESC"))))
  (is (= "Alan\n" (q "SELECT name FROM people ORDER BY age LIMIT 1")))
  (is (= "" (q "SELECT name FROM people LIMIT 0")))
  (testing "literal affinity"
    (is (= "Grace\n" (q "SELECT name FROM people WHERE age = '45.0' AND score < 2")))))

(deftest index-lookup
  (testing "entries on interior pages are found too"
    (is (= "1\tAda\t36\t1.0\n5\tCy\t36\t2.5\n" (q "INDEX people_age 36")))
    (is (= "2\tGrace\t45\t1.7\n4\tBob\t45\tNULL\n" (q "INDEX people_age '45'"))))
  (is (= "" (q "INDEX people_age NULL")))
  (is (= "" (q "INDEX people_age 40")))
  (is (= [[1 "Ada" 36 1.0] [5 "Cy" 36 2.5]] (sf/index-lookup db "PEOPLE_AGE" 36))))

(deftest overflow-chain
  (let [[[_ blob]] (sf/select db "blobs")]
    (is (= 1000 (alength ^bytes blob)))
    (is (= (vec fx/big-blob) (vec blob)))))

(deftest btree-primitives
  (let [p (:pager db)]
    (is (= [1 2 3 4 5] (btree/table-reduce p 2 (fn [acc rowid _] (conj acc rowid)) [])))
    (is (= [1 2] (btree/table-reduce p 2 (fn [acc rowid _]
                                           (let [acc (conj acc rowid)]
                                             (if (= 2 (count acc)) (reduced acc) acc))) [])))
    (is (some? (btree/table-find p 2 4)))
    (is (nil? (btree/table-find p 2 6)))))

(deftest errors
  (doseq [l ["SELECT nope FROM people" "SELECT * FROM nope" "SELECT * FROM v" "SELECT * FROM people_age"
             "SELECT * FROM sqlite_schema" "COUNT v" "INDEX people 1" "INDEX v 1"
             "INDEX sqlite_autoindex_blobs_1 1" "INDEX nope 1" "SELECT _rowid_ FROM people"
             "SELECT oid FROM people" "SELECT * FROM people WHERE nope = 1" "SELECT * FROM people ORDER BY nope"
             ".SCHEMA people" "SELECT * FROM people WHERE age == 1"]]
    (is (error? l) l)))

(deftest rejects-non-databases
  (is (thrown? clojure.lang.ExceptionInfo (pager/from-bytes (byte-array 200)))))
