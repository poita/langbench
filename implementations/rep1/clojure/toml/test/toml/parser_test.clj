(ns toml.parser-test
  (:require [clojure.test :refer [deftest is testing are]]
            [toml.core :as toml]
            [toml.json :as json]))

(defn- decode [s] (json/write-tagged (toml/parse-tagged s)))

(defn- invalid? [s]
  (try (toml/parse-tagged s) false
       (catch clojure.lang.ExceptionInfo e (boolean (:toml/error (ex-data e))))))

(deftest basics
  (is (= "{}" (decode "")))
  (is (= "{}" (decode "# just a comment\n\n  \n")))
  (is (= "{\"a\":{\"type\":\"integer\",\"value\":\"1\"}}" (decode "a = 1")))
  (is (= "{\"a\":{\"b\":{\"c\":{\"type\":\"bool\",\"value\":\"true\"}}}}" (decode "a . b . c = true")))
  (is (= {"a" 1} (toml/parse-string "a = 1 # c\r\n"))))

(deftest strings
  (are [src value] (= value (get (toml/parse-string src) "s"))
    "s = \"a\\tb\\u00e9\\U0001F600\"" "a\tb\u00e9\ud83d\ude00"
    "s = 'C:\\path'" "C:\\path"
    "s = \"\"\"\nline1\nline2\"\"\"" "line1\nline2"
    "s = \"\"\"a \\\n   b\"\"\"" "a b"
    "s = \"\"\"quote\"\"\"\"\"" "quote\"\""
    "s = '''\nraw \\n'''" "raw \\n"
    "s = \"\"\"a\r\nb\"\"\"" "a\nb"
    "s = \"\\u0000\"" "\u0000"))

(deftest key-forms
  (is (= {"a" "x" "b" "y" "" "z"}
         (toml/parse-string "a = 'x'\n\"b\" = \"y\"\n\"\" = 'z'")))
  (is (= {"a" {"b" 1}} (toml/parse-string "\"a\".'b' = 1")))
  (is (= {"1234" 1} (toml/parse-string "1234 = 1"))))

(deftest tables
  (is (= {"a" {"b" {"c" 1}}} (toml/parse-string "[a.b]\nc = 1")))
  (is (= {"a" {"x" 1 "b" {"y" 2}}} (toml/parse-string "[a.b]\ny = 2\n[a]\nx = 1")))
  (is (= {"f" [{"n" 1 "v" [{"m" 2}]} {"n" 3}]}
         (toml/parse-string "[[f]]\nn = 1\n[[f.v]]\nm = 2\n[[f]]\nn = 3")))
  (is (= {"a" {"b" 1 "c" 2}} (toml/parse-string "a.b = 1\na.c = 2")))
  (is (= {"a" {"b" {"c" 1 "d" {}}}} (toml/parse-string "[a]\nb.c = 1\n[a.b.d]\n"))
      "a header may pass through a dotted table")
  (is (= {"t" {"a" {"b" 1}}} (toml/parse-string "t = { a.b = 1 }"))))

(deftest arrays-and-inline-tables
  (is (= {"a" [1 "x" [2] {"k" 3}]} (toml/parse-string "a = [1, 'x', [2], {k = 3},]")))
  (is (= {"a" [1 2]} (toml/parse-string "a = [ # c\n 1,\n 2 # d\n ,\n]")))
  (is (= {"a" {"b" [1]}} (toml/parse-string "a = { b = [\n1\n]}"))))

(deftest rejected-documents
  (testing "syntax"
    (doseq [s ["a" "a =" "= 1" "a = 1 b = 2" "a = [1,,2]" "a = [,1]" "a = {b = 1,}"
               "a = {b = 1\n}" "a = \"x" "a = 'x\n'" "[a" "[[a]" "[ [a]]" "[a] x"
               "a = 1979-05-27 07:32" "a = 01" "a = .5" "a = tru" "a = TRUE"
               "a = \"\\q\"" "a = \"\\ud800\"" "a = \"\\U00110000\""
               "a = \"\"\"x\"\"\"\"\"\"" "a = 1 \u0000" "# c\u0001\n" "# c\u007f"]]
      (is (invalid? s) (pr-str s))))
  (testing "line endings"
    (doseq [s ["a = 1\r" "a = \"x\ry\"" "# c\rd" "a = 1\rb = 2" "a = '''\rx'''"]]
      (is (invalid? s) (pr-str s))))
  (testing "table rules"
    (doseq [s ["a = 1\na = 2" "a = 1\n[a]" "[a]\n[a]" "a.b = 1\n[a]" "[a]\nb.c = 1\n[a.b]"
               "a = {b = 1}\n[a.c]" "a = {b = 1}\na.c = 2" "a = [1]\n[[a]]" "[[a]]\n[a]"
               "a = [{b = 1}]\n[a.c]" "[a.b]\n[a]\nb.c = 1\n" "a = {b = 1, b = 2}"
               "[a]\nb = 1\n[a.b.c]" "[[a]]\nb = 1\n[a.b]\n[[a.b]]"]]
      (is (invalid? s) (pr-str s))))
  (testing "document level"
    (is (invalid? "\uFEFFa = 1"))
    (is (invalid? "a = \u0661"))
    (is (invalid? "a = 1979-05-27T07:32:00Z x"))))

(deftest error-positions
  (let [e (try (toml/parse-string "a = 1\nb = ?\n") (catch clojure.lang.ExceptionInfo e e))]
    (is (= 2 (:line (ex-data e))))
    (is (= 5 (:column (ex-data e))))))

(deftest deep-nesting
  (let [n 400]
    (is (= n (loop [v (toml/parse-string (str "a = " (apply str (repeat n "[")) (apply str (repeat n "]")))) k 0]
               (if (seq v) (recur (first (if (map? v) (vals v) v)) (inc k)) k)))
        "nested arrays")))
