(ns rubiks.cli-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [rubiks.cli :as cli]
            [rubiks.facelet :as facelet]
            [rubiks.moves :as moves]
            [rubiks.tables :as tables]))

(defn- tbl [] @tables/default-tables)

(deftest split-lines-test
  (is (= ["R"] (cli/split-lines "R\n")))
  (is (= ["R"] (cli/split-lines "R")))
  (is (= ["R" ""] (cli/split-lines "R\n\n")))
  (is (= ["F R U'" "" "R U"] (cli/split-lines "F R U'\n\nR U\n")))
  (is (= [""] (cli/split-lines "\n"))))

(deftest solve-line-test
  (is (= "R'" (cli/solve-line (tbl) "R")))
  (is (= "" (cli/solve-line (tbl) "")))
  (is (thrown? clojure.lang.ExceptionInfo (cli/solve-line (tbl) "R2'"))))

(deftest solve-text-test
  (testing "one output line per input line, each ending in a newline"
    (let [input "F R U'\n\nR U R' U' R U R' U' R U R' U' R U R' U' R U R' U' R U R' U'"
          output (cli/solve-text (tbl) input)
          lines (str/split output #"\n" -1)]
      (is (str/ends-with? output "\n"))
      (is (= 4 (count lines)) "three solutions plus the empty piece after the last newline")
      (is (= "" (nth lines 1)))
      (is (= "" (nth lines 2)))
      (let [sol (moves/parse (nth lines 0))]
        (is (facelet/solved? (facelet/apply-moves facelet/solved
                                                  (concat (moves/parse "F R U'") sol)))))))
  (testing "a trailing empty scramble gets an empty line"
    (is (= "R'\n\n" (cli/solve-text (tbl) "R\n\n")))
    (is (= "R'\n" (cli/solve-text (tbl) "R")))))
