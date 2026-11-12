(ns mime.mailbox-test
  (:require [clojure.test :refer [deftest is]]
            [mime.mailbox :as m]))

(defn- split [^String s] (mapv #(String. ^bytes % "UTF-8") (m/split-mbox (.getBytes s "UTF-8"))))

(deftest mbox-splitting
  (is (= ["A: 1\n\nbody\n"] (split "From x\nA: 1\n\nbody\n\n")))
  (is (= ["a\n" "b"] (split "junk\n\nFrom x\na\n\nFrom y\nb")))
  (is (= [] (split "no separator\n")))
  (is (= ["x\nFrom not-a-sep\n"] (split "From a\nx\nFrom not-a-sep\n"))
      "a From line not preceded by an empty line is body text")
  (is (= ["\n" "z"] (split "From a\n\nFrom b\nz")) "empty first message"))
