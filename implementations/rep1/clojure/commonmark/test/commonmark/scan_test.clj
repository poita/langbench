(ns commonmark.scan-test
  (:require [clojure.test :refer [deftest is testing]]
            [commonmark.scan :as scan]))

(deftest autolinks
  (testing "URI autolinks"
    (is (= [14 false] (scan/scan-autolink "<http://a.b/c> x" 0)))
    (is (= [8 false] (scan/scan-autolink "<a+b+c:>" 0)) "empty rest is allowed")
    (is (nil? (scan/scan-autolink "<m:abc>" 0)) "scheme needs at least two characters")
    (is (nil? (scan/scan-autolink "<http://a b>" 0)))
    (is (nil? (scan/scan-autolink "<http://a<b>" 0)))
    (is (nil? (scan/scan-autolink "<http://a.b" 0)))
    (is (nil? (scan/scan-autolink (str "<" (apply str (repeat 33 "a")) ":x>") 0))
        "scheme at most 32 characters"))
  (testing "email autolinks"
    (is (= [13 true] (scan/scan-autolink "<foo@bar.baz> x" 0)))
    (is (= [9 true] (scan/scan-autolink "<a+b@c.d>" 0)))
    (is (nil? (scan/scan-autolink "<foo@-bar.baz>" 0)))
    (is (nil? (scan/scan-autolink "<foo@bar-.baz>" 0)))
    (is (nil? (scan/scan-autolink "<foo@bar..baz>" 0)))
    (is (nil? (scan/scan-autolink (str "<foo@" (apply str (repeat 64 "a")) ">") 0))
        "labels are at most 63 characters")
    (is (nil? (scan/scan-autolink "<foo\\@bar.baz>" 0)))))

(deftest link-destinations
  (is (= ["/url" nil 6] (scan/scan-inline-link-tail "(/url)" 0)))
  (is (= ["" nil 2] (scan/scan-inline-link-tail "()" 0)))
  (is (= ["" nil 4] (scan/scan-inline-link-tail "(<>)" 0)))
  (is (= ["/my uri" nil 11] (scan/scan-inline-link-tail "(</my uri>)" 0)))
  (is (= ["a(b)c" nil 7] (scan/scan-inline-link-tail "(a(b)c)" 0)) "balanced parentheses")
  (is (= ["a(" nil 5] (scan/scan-inline-link-tail "(a\\()" 0)) "escaped parenthesis")
  (is (nil? (scan/scan-inline-link-tail "(/my uri)" 0)))
  (is (nil? (scan/scan-inline-link-tail "(<a\nb>)" 0)))
  (is (nil? (scan/scan-inline-link-tail "(<a<b>)" 0)))
  (is (nil? (scan/scan-inline-link-tail "(a(b)" 0)) "unbalanced")
  (is (nil? (scan/scan-inline-link-tail (str "(" (apply str (repeat 33 "(")) ")") 0))
      "more than 32 nested parentheses")
  (is (nil? (scan/scan-inline-link-tail "(a" 0)))
  (is (nil? (scan/scan-inline-link-tail "[a]" 0))))

(deftest link-titles
  (is (= ["/u" "t" 8] (scan/scan-inline-link-tail "(/u \"t\")" 0)))
  (is (= ["/u" "t" 8] (scan/scan-inline-link-tail "(/u 't')" 0)))
  (is (= ["/u" "t" 8] (scan/scan-inline-link-tail "(/u (t))" 0)))
  (is (= ["/u" "" 7] (scan/scan-inline-link-tail "(/u \"\")" 0)) "an empty title is still a title")
  (is (= ["/u" "a\"b" 11] (scan/scan-inline-link-tail "(/u \"a\\\"b\")" 0)))
  (is (= ["/u" "a\nb" 10] (scan/scan-inline-link-tail "(/u \"a\nb\")" 0)) "titles may span lines")
  (is (nil? (scan/scan-inline-link-tail "(/u \"t\"x)" 0)))
  (is (= ["/u\"t\"" nil 7] (scan/scan-inline-link-tail "(/u\"t\")" 0)) "without whitespace it is part of the destination")
  (is (nil? (scan/scan-inline-link-tail "(/u (a(b))" 0)) "unescaped open paren in a paren title")
  (testing "the longest title wins"
    (is (= 4 (scan/scan-link-title "\"a\\\"" 0)) "a trailing backslash-quote can close the title")
    (is (= 5 (scan/scan-link-title "\"a\\\"\"" 0)))
    (is (= -1 (scan/scan-link-title "abc" 0)))))
