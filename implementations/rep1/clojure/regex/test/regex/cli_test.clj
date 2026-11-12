(ns regex.cli-test
  (:require [clojure.test :refer [deftest is]]
            [regex.cli :as cli])
  (:import (java.io BufferedReader StringReader StringWriter)))

(defn- run [input]
  (let [out (StringWriter.)]
    (cli/process (BufferedReader. (StringReader. input)) out)
    (str out)))

(deftest format-result
  (is (= "no" (cli/format-result nil)))
  (is (= "match 2 7" (cli/format-result {:start 2 :end 7 :groups []})))
  (is (= "match 2 7|2,4|-|7,7"
         (cli/format-result {:start 2 :end 7 :groups [[2 4] nil [7 7]]}))))

(deftest spec-example-1
  (is (= (str "match 0 4|0,1|1,4|4,4\nmatch 0 0\nmatch 0 0\nmatch 0 4|0,4\nno\n")
         (run (str "3\n(a|ab)(c|bcd)(d*)\n1\nabcd\na*\n2\nbbb\n\n^(a+)+$\n2\naaaa\naaab\n")))))

(deftest positional-format
  ;; empty pattern, blank and space-only subjects, M = 0, integer-looking lines
  (is (= "match 0 0\nmatch 0 0\nmatch 0 0\n" (run "1\n\n3\n\n  \n12\n")))
  (is (= "" (run "2\na\n0\nb\n0\n")))
  (is (= "match 0 1\nno\n" (run "2\n1\n1\n1\n2\n1\n1\n"))))

(deftest spec-example-3
  (is (= "match 0 3|2,2\nno\nno\nmatch 0 2|0,1\nmatch 0 1|-\nmatch 1 2|-|-|-\nmatch 1 3|-|1,2|2,3\nmatch 0 1|-|-|0,1\n"
         (run (str "3\n(a*)*b\n2\naab\nccc\nx$|^(y)?z\n3\nxz\nyz\nzzz\n"
                   "(a){0}b|(c)?(d)\n3\nxb\nxcd\nd\n")))))
