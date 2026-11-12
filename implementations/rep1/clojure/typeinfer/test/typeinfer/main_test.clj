(ns typeinfer.main-test
  (:require [clojure.test :refer [deftest is]]
            [typeinfer.main :as main])
  (:import (java.io ByteArrayInputStream ByteArrayOutputStream)))

(defn- run-cli [^String input]
  (let [out (ByteArrayOutputStream.)
        code (main/run (ByteArrayInputStream. (.getBytes input "UTF-8")) out)]
    [code (.toString out "UTF-8")]))

(deftest cli-contract-test
  (is (= [0 "id : 'a -> 'a\n- : int\nerror: unify\n"]
         (run-cli "let id x = x;; id 1;; 1 true;;")))
  (is (= [0 ""] (run-cli "")))
  (is (= [0 "error: unbound\n"] (run-cli "x;;"))))

(deftest cli-malformed-input-test
  (is (= [1 "a : int\n"] (run-cli "let a = 1;; let b = ;;"))))
