(ns depresolve.version-test
  (:require [clojure.test :refer [deftest is testing]]
            [depresolve.version :as v]))

(deftest parse-and-format
  (is (= "1.10.0" (v/fmt (v/parse "1.10.0"))))
  (is (= "0.0.0" (v/fmt (v/parse "0.0.0"))))
  (is (= "1000000.1000000.1000000" (v/fmt (v/parse "1000000.1000000.1000000")))))

(deftest ordering-is-numeric
  (is (< (v/parse "1.9.0") (v/parse "1.10.0")))
  (is (< (v/parse "1.999999.999999") (v/parse "2.0.0")))
  (is (< (v/parse "0.0.1") (v/parse "0.1.0")))
  (testing "successor"
    (is (= (inc (v/parse "1.2.3")) (v/parse "1.2.4")))))
