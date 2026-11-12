(ns depresolve.version-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [depresolve.version :as v]))

(deftest parse-and-format
  (is (= [1 10 0] (v/parse "1.10.0")))
  (is (= [0 0 0] (v/parse "0.0.0")))
  (is (= [1000000 1000000 1000000] (v/parse "1000000.1000000.1000000")))
  (is (= "1.10.0" (v/fmt [1 10 0]))))

(deftest ordering-is-numeric
  (is (v/newer? (v/parse "1.10.0") (v/parse "1.9.0")))
  (is (v/newer? (v/parse "2.0.0") (v/parse "1.999.999")))
  (is (not (v/newer? [1 2 3] [1 2 3]))))

(deftest successor
  (is (= [1 2 4] (v/successor [1 2 3]))))

(def gen-version (gen/vector (gen/choose 0 1000001) 3))

(defspec encode-roundtrips 200
  (prop/for-all [x gen-version]
    (= x (v/decode (v/encode x)))))

(defspec encode-preserves-order 500
  (prop/for-all [a gen-version b gen-version]
    (= (compare a b) (compare (v/encode a) (v/encode b)))))

(deftest valid
  (testing "well-formed versions"
    (is (v/valid? [1 2 3]))
    (is (not (v/valid? [1 2])))
    (is (not (v/valid? [1 -2 3])))
    (is (not (v/valid? "1.2.3")))))
