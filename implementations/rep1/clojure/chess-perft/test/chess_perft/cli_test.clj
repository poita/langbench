(ns chess-perft.cli-test
  (:require [chess-perft.cli :as cli]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing]])
  (:import [java.io BufferedReader StringReader StringWriter]))

(defn- run-cli [input]
  (let [out (StringWriter.)]
    (cli/run (BufferedReader. (StringReader. input)) out)
    (str out)))

(deftest parse-query
  (is (= {:fen "8/8/8/8/8/8/8/4K2k w - - 0 1" :divide? false :depth 3}
         (cli/parse-query "8/8/8/8/8/8/8/4K2k w - - 0 1 3")))
  (is (= {:fen "8/8/8/8/8/8/8/4K2k w - - 0 1" :divide? true :depth 2}
         (cli/parse-query "8/8/8/8/8/8/8/4K2k w - - 0 1 divide 2"))))

(deftest spec-examples
  (is (= "20\n8902\n1\n"
         (run-cli (str "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 1\n"
                       "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 3\n"
                       "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1 0"))))
  (is (= (str "a6a5 1\na6b5 1\na7a8b 1\na7a8n 1\na7a8q 1\na7a8r 1\ntotal 6\n")
         (run-cli "8/P1k5/K7/8/8/8/8/8 w - - 0 1 divide 1\n")))
  (is (= "total 0\n" (run-cli "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1 divide 3\n"))))

(deftest empty-input
  (is (= "" (run-cli "")))
  (is (= "" (run-cli "\n"))))

(deftest divide-total-line
  (let [lines (str/split-lines
               (run-cli "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 divide 3\n"))]
    (is (= 21 (count lines)))
    (is (= "total 8902" (last lines)))
    (is (= "a2a3 380" (first lines)))))
