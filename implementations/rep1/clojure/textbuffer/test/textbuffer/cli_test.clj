(ns textbuffer.cli-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [textbuffer.cli :as cli])
  (:import (java.io StringReader StringWriter)))

(defn- run-cli [input]
  (let [out (StringWriter.)]
    (cli/run (StringReader. input) out)
    (str out)))

(deftest spec-example-1
  (is (= (str "hello, world!\nsecond line (edited)\ncursor 0 6\n--\n"
              "hell world!\nsecond line (edited)\ncursor 0 4\n--\n")
         (run-cli (str/join "\n" ["2" "hello world" "second line"
                                  "move end" "insert !" "move down" "insert  (edited)"
                                  "goto 0 5" "insert ," "print" "delete" "delete" "print"])))))

(deftest spec-example-2
  (is (= (str "- alpha\n- beta\n- gamma\ncursor 0 2\ncursor 1 2\ncursor 2 2\n--\n"
              "- X\n- X\n- X\ncursor 0 3\ncursor 1 3\ncursor 2 3\n--\n"
              "-\n- X\n- X\ncursor 0 1\n--\n")
         (run-cli (str/join "\n" ["3" "alpha" "beta" "gamma"
                                  "add-cursor 1 0" "add-cursor 2 0" "insert - " "print"
                                  "move end select" "insert X" "print"
                                  "goto 0 1" "move right select" "move right select"
                                  "delete" "print"])))))

(deftest spec-example-3
  (is (= (str "abcd\ne\ncursor 1 1\n--\n"
              "abcd\ncursor 0 4\n--\n"
              "abcd\n\ncursor 1 0\n--\n"
              "abcd\ne\ncursor 1 1\n--\n"
              "abcd\n\ncursor 1 0\n--\n"
              "abcd\nZ\ncursor 1 1\n--\n")
         (run-cli (str/join "\n" ["1" "abc" "move end" "insert d\\ne" "print"
                                  "delete" "delete" "print" "undo" "print" "undo" "print"
                                  "redo" "print" "insert Z" "redo" "print" ""])))))

(deftest document-lines-are-verbatim
  (testing "lines that look like commands, leading and trailing spaces, empty lines"
    (is (= "  print \n\nundo\ncursor 0 0\n--\n"
           (run-cli "3\n  print \n\nundo\nprint")))))

(deftest empty-document-and-no-prints
  (is (= "\ncursor 0 0\n--\n" (run-cli "0\nprint\n")))
  (is (= "" (run-cli "1\nabc\ninsert x\n")))
  (is (= "" (run-cli "0"))))

(deftest bad-command
  (is (thrown? clojure.lang.ExceptionInfo (run-cli "0\nbogus\n"))))
