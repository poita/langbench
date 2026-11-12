(ns regex.property-test
  "Randomised comparison of the VM against the naive reference matcher."
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [regex.core :as re]
            [regex.reference :as ref]))

(def ^:private gen-charclass
  (gen/elements ["[ab]" "[^a]" "[a-b]" "[^ab]" "\\w" "\\W" "\\d" "\\S" "[-a]" "[b-]"]))

(def ^:private gen-simple
  (gen/frequency [[6 (gen/elements ["a" "b" "c"])]
                  [2 (gen/return ".")]
                  [2 gen-charclass]]))

(def ^:private gen-quant
  (gen/frequency [[5 (gen/return "")]
                  [2 (gen/return "*")] [2 (gen/return "+")] [2 (gen/return "?")]
                  [1 (gen/elements ["{0}" "{2}" "{1,}" "{0,2}" "{1,3}"])]]))

;; Counted quantifiers on whole groups multiply the work of the (exponential)
;; reference matcher, so groups only get the simple quantifiers.
(def ^:private gen-group-quant
  (gen/elements ["" "" "*" "+" "?" "{2}" "{0,2}"]))

(defn- gen-regex
  "Generator of pattern strings; `depth` bounds group nesting."
  [depth]
  (let [piece (gen/frequency
               (concat
                [[6 (gen/let [a gen-simple q gen-quant] (str a q))]
                 [1 (gen/elements ["^" "$"])]]
                (when (pos? depth)
                  [[3 (gen/let [body (gen/bind (gen/return nil) (fn [_] (gen-regex (dec depth)))) q gen-group-quant]
                        (str "(" body ")" q))]])))
        branch (gen/fmap #(apply str %) (gen/vector piece 0 3))]
    (gen/fmap #(clojure.string/join "|" %) (gen/vector branch 1 2))))

(def ^:private gen-subject
  (gen/fmap #(apply str %) (gen/vector (gen/elements [\a \b \c \5 \_ \space]) 0 9)))

(defspec vm-agrees-with-reference 1000
  (prop/for-all [pattern (gen-regex 3)
                 subjects (gen/vector gen-subject 1 6)]
    (let [r (re/compile pattern)]
      (every? (fn [s]
                (let [expected (ref/find-match pattern s)
                      actual (re/find-match r s)]
                  (or (= expected actual)
                      (do (println "MISMATCH" (pr-str pattern) (pr-str s)
                                   "expected" expected "actual" actual)
                          false))))
              subjects))))

(deftest workspace-reuse-is-clean
  ;; many searches through one workspace give the same answers as fresh ones
  (let [pattern "(a|(b))*c?(d|)"
        r (re/compile pattern)]
    (doseq [s ["ab" "ba" "abc" "x" "" "abab" "bbd" "cd"]]
      (is (= (ref/find-match pattern s) (re/find-match r s))))))
