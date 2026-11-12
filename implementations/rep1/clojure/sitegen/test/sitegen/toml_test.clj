(ns sitegen.toml-test
  (:require [clojure.test :refer [deftest is testing]]
            [sitegen.toml :as toml]))

(defn- parse [s] (into {} (toml/parse-document s)))

(deftest values
  (testing "the four value forms"
    (is (= {"s" "x" "i" 12 "n" -4 "z" 0 "t" true "f" false "a" ["p" "q"]}
           (parse "s = \"x\"\ni = 12\nn = -4\nz = 0\nt = true\nf = false\na = [\"p\", \"q\"]"))))
  (testing "string escapes"
    (is (= {"k" "a\"b\\c\nd\te\rf\u00e9g"}
           (parse "k = \"a\\\"b\\\\c\\nd\\te\\rf\\u00e9g\"")))
    (is (= {"k" "\u1F600"} (parse "k = \"\\u1F600\""))
        "\\u takes exactly four hex digits"))
  (testing "a # inside a string is not a comment"
    (is (= {"k" "a # b"} (parse "k = \"a # b\" # comment"))))
  (testing "arrays: whitespace, trailing comma, empty"
    (is (= {"a" ["x" "y"]} (parse "a = [ \"x\" ,\t\"y\" , ]")))
    (is (= {"a" []} (parse "a = []")))
    (is (= {"a" []} (parse "a = [ ]"))))
  (testing "non-ASCII text stands for itself"
    (is (= {"k" "日本 ' x"} (parse "k = \"日本 ' x\"")))))

(deftest layout
  (testing "blank lines and comments are ignored"
    (is (= {"a" 1} (parse "\n  \t \n# comment\n   # another\na = 1\n\n"))))
  (testing "spacing around =, and key characters"
    (is (= {"a-b_C9" 1} (parse "  a-b_C9\t=   1   "))))
  (testing "keys keep file order"
    (is (= ["z" "a" "m" "b" "y" "c" "x" "d" "w" "e"]
           (vec (keys (toml/parse-document
                       (apply str (map #(str % " = 1\n") ["z" "a" "m" "b" "y" "c" "x" "d" "w" "e"])))))))))

(deftest errors
  (doseq [bad ["a" "a =" "a = b" "a = \"x" "a = 01" "a = [1]" "a = \"x\" y" "= 1" "a = \"\\q\"" "a = [\"x\" \"y\"]"]]
    (testing bad
      (is (thrown? clojure.lang.ExceptionInfo (toml/parse-document bad))))))
