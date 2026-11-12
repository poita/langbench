(ns buildsys.hash-test
  (:require [buildsys.hash :as hash]
            [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]))

(deftest known-values
  (is (= "cbf29ce484222325" (hash/hash-hex "")))
  (is (= "a9bc80cca21f28b3" (hash/hash-hex "hello\n")))
  (is (= "fc17b183ee074373" (hash/hash-hex "abc\n"))))

(deftest bytes-are-zero-extended
  (testing "bytes above 0x7f hash as unsigned values"
    (is (not= (hash/hash-hex "ÿ") (hash/hash-hex "\u007f")))
    (is (= 16 (count (hash/hash-hex "éü"))))))

(defspec hex-is-always-sixteen-digits 200
  (prop/for-all [s (gen/fmap #(apply str (map char %))
                             (gen/vector (gen/choose 0 255) 0 64))]
    (boolean (re-matches #"[0-9a-f]{16}" (hash/hash-hex s)))))
