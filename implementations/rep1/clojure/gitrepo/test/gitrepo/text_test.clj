(ns gitrepo.text-test
  (:require [clojure.test :refer [deftest is are]]
            [gitrepo.object :as obj]
            [gitrepo.quote :as quote]))

(deftest path-quoting
  (are [in out] (= out (quote/quote-path in))
    "plain.txt" "plain.txt"
    "with space" "with space"
    "cafÃ©.txt" "\"caf\\303\\251.txt\""
    "quote\"and\\slash.txt" "\"quote\\\"and\\\\slash.txt\""
    "tab\there" "\"tab\\there\""
    "ctl\u0001x" "\"ctl\\001x\""
    "del\u007fx" "\"del\\177x\""))

(deftest subjects
  (are [msg subj] (= subj (obj/subject msg))
    "\n\nFix the thing   \nand the other\n\nbody\n" "Fix the thing and the other"
    "" ""
    "\n  \n\t\n" ""
    "one line" "one line"
    "a\r\nb\r\n\r\nc" "a b"))

(deftest idents
  (are [line name ts] (= {:name name :timestamp ts} (obj/parse-ident line))
    "Ada Lovelace <ada@x.org> 1400003600 +0100" "Ada Lovelace" 1400003600
    "Ada  <ada@x.org>   42 +0000" "Ada" 42
    "No Time <n@x.org>" "No Time" 0
    "Signed <n@x.org> -17 +0000" "Signed" 17
    nil "" 0))

(deftest commit-headers
  (let [c (obj/parse-commit
           (.getBytes (str "tree " (apply str (repeat 40 \a)) "\n"
                           "parent " (apply str (repeat 40 \b)) "\n"
                           "parent " (apply str (repeat 40 \c)) "\n"
                           "author A <a@x> 5 +0000\n"
                           "author B <b@x> 6 +0000\n"
                           "gpgsig -----BEGIN\n continued\n -----END\n"
                           "committer C <c@x> 7 +0000\n"
                           "\nthe message\n")
                      "ISO-8859-1"))]
    (is (= [(apply str (repeat 40 \b)) (apply str (repeat 40 \c))] (:parents c)))
    (is (= "B" (:name (:author c))))
    (is (= 7 (:timestamp (:committer c))))
    (is (= "the message\n" (:message c)))))
