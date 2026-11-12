(ns fulltext.stemmer-test
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [fulltext.stemmer :as stemmer]))

(defn- check-stems [pairs]
  (doseq [[word expected] pairs]
    (is (= expected (stemmer/stem word)) word)))

(deftest short-words-unchanged
  (check-stems [["a" "a"] ["is" "is"] ["as" "as"] ["us" "us"]]))

(deftest worked-stems
  (check-stems
   [["running" "run"] ["runs" "run"] ["runner" "runner"]
    ["connection" "connect"] ["connections" "connect"] ["connecting" "connect"]
    ["cats" "cat"] ["dogs" "dog"] ["happiness" "happi"] ["happier" "happier"]
    ["relational" "relat"] ["relativity" "rel"] ["sensibility" "sensibl"]
    ["national" "nation"] ["controlled" "control"] ["abandoned" "abandon"]]))

(deftest step-1-selection-rule
  (testing "a matching suffix selects its rule even when its condition fails"
    (check-stems [["feed" "feed"] ["need" "need"] ["bleed" "bleed"]
                  ["deed" "deed"] ["agreed" "agre"]]))
  (testing "1a"
    (check-stems [["caresses" "caress"] ["ponies" "poni"] ["ties" "ti"]
                  ["caress" "caress"] ["cats" "cat"]]))
  (testing "1b clean-up chain"
    (check-stems [["conflated" "conflat"] ["troubled" "troubl"] ["sized" "size"]
                  ["hopping" "hop"] ["tanned" "tan"] ["falling" "fall"]
                  ["hissing" "hiss"] ["fizzed" "fizz"] ["failing" "fail"]
                  ["filing" "file"]]))
  (testing "1c"
    (check-stems [["happy" "happi"] ["sky" "sky"]])))

(deftest later-steps
  (check-stems
   [["conditional" "condit"] ["valenci" "valenc"] ["digitizer" "digit"]
    ["conformabli" "conform"] ["radicalli" "radic"] ["vietnamization" "vietnam"]
    ["predication" "predic"] ["operator" "oper"] ["feudalism" "feudal"]
    ["decisiveness" "decis"] ["hopefulness" "hope"] ["callousness" "callous"]
    ["triplicate" "triplic"] ["formative" "form"] ["formalize" "formal"]
    ["electrical" "electr"] ["goodness" "good"]
    ["revival" "reviv"] ["allowance" "allow"] ["inference" "infer"]
    ["adjustment" "adjust"] ["adoption" "adopt"] ["effective" "effect"]
    ["probate" "probat"] ["rate" "rate"] ["cease" "ceas"]
    ["controll" "control"] ["roll" "roll"]]))

(deftest porter-vocabulary
  (let [lines (fn [path] (str/split-lines (slurp (io/resource path))))
        words (lines "porter/voc.txt")
        stems (lines "porter/output.txt")]
    (is (= 23531 (count words)))
    (is (= (count words) (count stems)))
    (let [bad (remove nil?
                      (map (fn [w s] (when (not= s (stemmer/stem w)) [w s (stemmer/stem w)]))
                           words stems))]
      (is (empty? (take 10 bad))))))
