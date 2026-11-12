(ns langvm.source-test
  (:require [clojure.test :refer [deftest is testing]]
            [langvm.diag :as diag]
            [langvm.source :as source]))

(defn- diag-of [text]
  (try (source/split-modules text) nil
       (catch clojure.lang.ExceptionInfo e (diag/format-diag e))))

(deftest line-splitting
  (is (= [] (source/split-lines "")))
  (is (= ["a" "b"] (source/split-lines "a\nb")))
  (is (= ["a" "b"] (source/split-lines "a\r\nb\n")))
  (is (= ["a\r" "b"] (source/split-lines "a\r\r\nb")) "only one CR before LF is dropped")
  (is (= ["" "x"] (source/split-lines "\nx"))))

(deftest module-splitting
  (let [ms (source/split-modules "@module a\nfn x\n@module b\n\nfn y\n")]
    (is (= ["a" "b"] (map :name ms)))
    (is (= [["fn x"] ["" "fn y"]] (map :lines ms)))
    (is (= [1 3] (map :header-line ms)))))

(deftest module-stream-errors
  (testing "no header"
    (is (= "error: bad-module at 1:1" (diag-of "")))
    (is (= "error: bad-module at 1:1" (diag-of "fn main() {}\n")))
    (is (= "error: bad-module at 1:1" (diag-of "@module 1x\n"))))
  (testing "malformed headers are not headers"
    (is (= "error: bad-module at 2:1" (diag-of "@module a\n@module  b\n")))
    (is (= "error: bad-module at 2:1" (diag-of "@module a\n@module b \n")))
    (is (= "error: bad-module at 2:1" (diag-of "@module a\n@module fn\n")))
    (is (= "error: bad-module at 3:1" (diag-of "@module a\nx\n@oops\n"))))
  (testing "duplicates use whole-input line numbers"
    (is (= "error: dup-module at 4:1" (diag-of "@module a\nx\n@module b\n@module a\n")))))
