(ns scheme.reader-test
  (:require [clojure.test :refer [deftest is testing]]
            [scheme.printer :as p]
            [scheme.reader :as r]
            [scheme.types :as t]))

(defn- rt "Read `src` and write the first datum back." [src]
  (p/write-str (first (r/read-all src))))

(deftest atoms
  (is (= [42 -7 5 7 0] (r/read-all "42 -7 +5 007 -0")))
  (is (= [true false] (r/read-all "#t #f")))
  (is (= "99999999999999999999999" (rt "99999999999999999999999")))
  (testing "symbols"
    (is (every? #(instance? scheme.types.Sym %)
                (r/read-all "+ - ... set! list->string <= a.b 1+ Foo")))
    (is (identical? (t/intern-sym "foo") (first (r/read-all "foo"))))
    (is (not (identical? (first (r/read-all "Foo")) (first (r/read-all "foo")))))))

(deftest strings
  (is (= ["a\"b\\c\nd\te"] (r/read-all "\"a\\\"b\\\\c\\nd\\te\"")))
  (is (= ["line1\nline2"] (r/read-all "\"line1\nline2\""))))

(deftest lists
  (is (= "()" (rt "()")))
  (is (= "(1 2 3)" (rt "(1   2\t3)")))
  (is (= "(1 2 . 3)" (rt "(1 2 . 3)")))
  (is (= "(1 . 2)" (rt "(1 . 2)")))
  (is (= "(quote a)" (rt "'a")))
  (is (= "(quote (1 (quote b)))" (rt "'(1 'b)")))
  (is (= "(...)" (rt "(...)"))))

(deftest comments-and-whitespace
  (is (= [1 2] (r/read-all "; hi\n1 ;; two\r\n 2 ; end")))
  (is (= [] (r/read-all "   \n ; only a comment"))))

(deftest incremental-reading
  (let [rd (r/reader "1 2")]
    (is (= 1 (r/read-datum rd)))
    (is (= 2 (r/read-datum rd)))
    (is (identical? r/eof (r/read-datum rd)))))

(deftest malformed
  (is (thrown? clojure.lang.ExceptionInfo (r/read-all "(1 2")))
  (is (r/syntax-error? (try (r/read-all "\"abc") (catch Exception e e)))))
