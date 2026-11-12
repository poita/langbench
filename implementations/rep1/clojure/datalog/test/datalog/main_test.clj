(ns datalog.main-test
  (:require [clojure.test :refer [deftest is]]
            [datalog.main :as main])
  (:import (java.io ByteArrayInputStream)))

(defn- cli [^String input]
  (let [old System/in]
    (try
      (System/setIn (ByteArrayInputStream. (.getBytes input "UTF-8")))
      (with-out-str (main/-main))
      (finally (System/setIn old)))))

(deftest cli-contract-test
  (is (= "p(1)\n-- 1\n" (cli "p(1). ?- p(X).")))
  (is (= "error\n" (cli "p(X).")))
  (is (= "error\n" (cli "p(1) :- q(1), not p(1). ?- p(X).")))
  (is (= "" (cli ""))))
