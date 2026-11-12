(ns sqlitefile.query-test
  (:require [clojure.test :refer [deftest is testing are]]
            [sqlitefile.query :as q]))

(defn- bad? [line]
  (try (q/parse line) false
       (catch clojure.lang.ExceptionInfo e (= :sqlitefile/syntax (:type (ex-data e))))))

(deftest dot-commands
  (is (= {:op :tables} (q/parse ".tables")))
  (is (= {:op :schema :table "people"} (q/parse ".schema people")))
  (doseq [l [".TABLES" ".SCHEMA t" ".schema" ".schema 9bad" ".schema people;" ".schema a b" ".tables x" ".foo"]]
    (is (bad? l) l)))

(deftest count-and-index
  (is (= {:op :count :table "t"} (q/parse "count\tt")))
  (is (bad? "COUNTt"))
  (is (bad? "COUNT t extra"))
  (is (= {:op :index :index "i" :literal 45} (q/parse "INDEX i 45")))
  (is (= {:op :index :index "i" :literal "x"} (q/parse "INDEX i'x'")))
  (is (= {:op :index :index "i" :literal -5} (q/parse "INDEX i-5")))
  (is (bad? "INDEX i")))

(deftest select-forms
  (is (= {:op :select :columns :all :table "t"} (q/parse "SELECT*FROM t")))
  (is (= {:op :select :columns ["a" "b"] :table "t"} (q/parse "select  a ,b\tfrom  t")))
  (is (= {:op :select :columns ["a"] :table "t"
          :where [{:column "a" :op :>= :literal 1}
                  {:column "b" :op :is-not :literal nil}
                  {:column "c" :op := :literal "it's"}]
          :order {:column "a" :desc? true}
          :limit 3}
         (q/parse "SELECT a FROM t WHERE a>=1 AND b IS\tNOT NULL AND c='it''s' ORDER BY a DESC LIMIT 3"))))

(deftest literals
  (let [lit #(:literal (first (:where (q/parse (str "SELECT * FROM t WHERE a = " %)))))]
    (are [text v] (= v (lit text))
      "7" 7 "+7" 7 "-9223372036854775808" Long/MIN_VALUE
      "1.5" 1.5 "1." 1.0 "-2.5e-3" -0.0025 "1E2" 100.0
      "'a'" "a" "''" "" "NULL" nil "null" nil)
    (is (= [0 255] (vec (map #(bit-and 0xff %) (lit "X'00fF'")))))
    (is (= [] (vec (lit "x''"))))
    (doseq [t [".5" "1e" "'abc" "X'0'" "X'zz'" "1.5.2" "12abc" "NULLS" ""]]
      (is (bad? (str "SELECT * FROM t WHERE a = " t)) t))))

(deftest malformed-selects
  (doseq [l ["SELECTa FROM t" "SELECT a FROMt" "SELECT FROM t" "SELECT a,FROM t" "SELECT * FROM"
             "SELECT * FROM t WHERE" "SELECT * FROM t WHERE a == 1" "SELECT * FROM t WHERE a <> 1"
             "SELECT * FROM t WHERE a ISNULL" "SELECT * FROM t WHERE a=1 b=2"
             "SELECT * FROM t WHERE a=1AND b=2" "SELECT * FROM t ORDERBY a"
             "SELECT * FROM t ORDER BY a ASC DESC" "SELECT * FROM t LIMIT -1"
             "SELECT * FROM t LIMIT3" "SELECT * FROM t LIMIT 3 extra"
             "SELECT * FROM t LIMIT 1 ORDER BY a" "SELECT * FROM t;" "" "DROP TABLE t"]]
    (is (bad? l) l)))
