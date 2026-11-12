(ns buildsys.hash-test
  (:require [buildsys.hash :as h]
            [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]))

(deftest known-vectors
  (is (= "cbf29ce484222325" (h/hash-hex "")))
  (is (= "a9bc80cca21f28b3" (h/hash-hex "hello\n")))
  (is (= "fc17b183ee074373" (h/hash-hex "abc\n"))))

(deftest bytes-are-zero-extended
  (is (= (h/hash-hex "ÿ") (h/hash-hex (String. (byte-array [-1]) "ISO-8859-1")))))

(defspec hex-is-sixteen-lowercase-digits 100
  (prop/for-all [s (gen/fmap #(apply str (map char %)) (gen/vector (gen/choose 0 255)))]
    (boolean (re-matches #"[0-9a-f]{16}" (h/hash-hex s)))))
