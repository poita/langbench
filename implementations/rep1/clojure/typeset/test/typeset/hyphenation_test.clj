(ns typeset.hyphenation-test
  (:require [clojure.test :refer [deftest is testing]]
            [typeset.hyphenation :as hy]
            [typeset.test-util :as t]))

(def english (delay (hy/load-patterns t/data-dir "english")))
(def minimal (delay (hy/load-patterns t/data-dir "minimal")))

(deftest pattern-files
  (is (= 2 (:left @english)))
  (is (= 3 (:right @english)))
  (is (= 145 (count (:patterns @english))))
  (is (= 9 (count (:exceptions @english))))
  (is (= 2 (:right @minimal))))

(deftest pattern-parsing
  (let [h (hy/parse-patterns "chp 1\nleft 1\nright 1\npattern .anti3\npattern c2h\npattern 3tion\nexception al-go-rithm\n")]
    (is (= [0 0 0 0 0 3] (vec (get-in h [:patterns ".anti"]))))
    (is (= [0 2 0] (vec (get-in h [:patterns "ch"]))))
    (is (= [3 0 0 0 0] (vec (get-in h [:patterns "tion"]))))
    (is (= [2 4] (get-in h [:exceptions "algorithm"])))))

(deftest worked-traces
  (is (= [3] (hy/breaks @english "winter")))
  (is (= [7 8] (hy/breaks @english "typesetting")))
  (is (= [2 4] (hy/breaks @english "national")))
  (is (= [2 8] (hy/breaks @english "introduction")))
  (testing "an exception overrides the patterns"
    (is (= [2 4] (hy/breaks @english "algorithm"))))
  (testing "short words never break"
    (is (= [] (hy/breaks @english "a")))
    (is (= [] (hy/breaks @english "the")))))
