(ns cardgame.golden-test
  "End-to-end tests: every `NAME.in` under test/resources/golden is run
  through `cardgame.core/run-match` and compared with `NAME.out` (ignoring
  trailing whitespace, as the contract allows)."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [cardgame.core :as cg]))

(defn- norm [s]
  (->> (str/split s #"\n" -1)
       (map str/trimr)
       (str/join "\n")
       str/trimr))

(deftest golden-matches
  (doseq [f (sort-by #(.getName ^java.io.File %) (.listFiles (io/file "test/resources/golden")))
          :when (str/ends-with? (.getName f) ".in")]
    (testing (.getName f)
      (let [expected (slurp (str/replace (str f) #"\.in$" ".out"))]
        (is (= (norm expected) (norm (cg/run-match (slurp f)))))))))

(deftest fatal-setup-problems
  (testing "bad-setup"
    (is (= "FATAL bad-setup\n" (cg/run-match "CARDS x\nSTART\n")))
    (is (= "FATAL bad-setup\n" (cg/run-match "")))
    (is (= "FATAL bad-setup\n" (cg/run-match "CARDS x\nSEED 1\nSPIRE 0\nSTART\n"))))
  (testing "bad-database"
    (is (= "FATAL bad-database\n" (cg/run-match "CARDS test/resources/missing.spire\nSEED 1\nSTART\n"))))
  (testing "unknown-card"
    (is (= "FATAL unknown-card\n"
           (cg/run-match "CARDS test/resources/mini.spire\nSEED 1\nDECK A ZZZ-999\nSTART\n")))))

(deftest comments-count-for-line-numbers
  (let [out (cg/run-match (str "CARDS test/resources/mini.spire\nSEED 1\nOPENING 0\nSHUFFLE off\n"
                               "START\n# comment\n\nX PASS\nA PASS 1\n"))]
    (is (str/includes? out "ERR 8 bad-syntax\nERR 9 bad-syntax\n"))))

(deftest trace-prints-a-block-after-accepted-actions-only
  (let [out (cg/run-match (str "CARDS test/resources/mini.spire\nSEED 1\nOPENING 0\nSHUFFLE off\n"
                               "TRACE legal\nSTART\nB PASS\nA PASS\nDUMP\n"))]
    (is (= 1 (count (re-seq #"LEGAL BEGIN" out))) "only the accepted PASS prints a block")
    (is (str/includes? out "ERR 7 not-your-turn"))
    (is (= 1 (count (re-seq #"STATE BEGIN" out))))))
