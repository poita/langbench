(ns regex.core-test
  (:require [clojure.test :refer [deftest is testing are]]
            [regex.core :as re]))

(defn- m
  "Match and flatten to [start end & groups] for compact assertions."
  [pattern subject]
  (when-let [r (re/re-match pattern subject)]
    (into [(:start r) (:end r)] (:groups r))))

(deftest spec-examples
  (is (= [0 4 [0 1] [1 4] [4 4]] (m "(a|ab)(c|bcd)(d*)" "abcd")))
  (is (= [0 0] (m "a*" "bbb")))
  (is (= [0 0] (m "a*" "")))
  (is (= [0 4 [0 4]] (m "^(a+)+$" "aaaa")))
  (is (nil? (m "^(a+)+$" "aaab")))
  (is (= [0 2 [1 2] [0 1]] (m "(a|(b))+" "ba")))
  (is (= [0 2 [1 2] [1 2]] (m "(a|(b))+" "ab")))
  (is (= [1 6] (m "[^a-c]\\d{2,3}x?" "zz123xx")))
  (is (nil? (m "[^a-c]\\d{2,3}x?" "abc9")))
  (is (= [0 3 [2 2]] (m "(a*)*b" "aab")))
  (is (nil? (m "x$|^(y)?z" "xz")))
  (is (= [0 2 [0 1]] (m "x$|^(y)?z" "yz")))
  (is (= [1 2 nil nil nil] (m "(a){0}b|(c)?(d)" "xb")))
  (is (= [1 3 nil [1 2] [2 3]] (m "(a){0}b|(c)?(d)" "xcd")))
  (is (= [0 1 nil nil [0 1]] (m "(a){0}b|(c)?(d)" "d"))))

(deftest ordered-choice-and-greed
  (is (= [0 1] (m "a|ab" "ab")))
  (is (= [0 3] (m "a*" "aaa")))
  (is (= [0 2] (m "a{1,2}" "aaa")))
  (is (= [0 3] (m "a*a" "aaa")))
  (is (= [1 4] (m "b+" "abbb")))
  (is (= [0 0 nil] (m "(a)?" "b"))))

(deftest anchors
  (is (nil? (m "a^b" "ab")))
  (is (= [0 0] (m "^" "abc")))
  (is (= [3 3] (m "$" "abc")))
  (is (= [2 3] (m "c$" "abc")))
  (is (= [0 0] (m "^$" ""))))

(deftest classes-and-escapes
  (is (= [1 4] (m "[a-c]+" "xabcx")))
  (is (= [0 3] (m "[-a]+" "-a-b")))
  (is (= [0 2] (m "[a-]+" "a-b")))
  (is (= [0 3] (m "[\\]\\[x]+" "][x!")))
  (is (= [1 4] (m "\\d+" "a123")))
  (is (= [0 3] (m "\\w+" "a_1 b")))
  (is (= [3 4] (m "\\W" "a_1 b")))
  (is (= [1 2] (m "\\s" "a b")))
  (is (= [0 2] (m "\\.\\*" ".*")))
  (is (= [0 1] (m "[^\\d]" "a1")))
  (is (= [1 2] (m "[\\D]" "1a"))))

(deftest counted-quantifiers
  (is (= [0 0 [0 0]] (m "(a*){3}" "")))
  (is (= [0 3] (m "a{3}" "aaaa")))
  (is (= [0 4] (m "a{2,}" "aaaa")))
  (is (= [0 0] (m "a{0}" "aaa")))
  (is (nil? (m "a{3}" "aa")))
  (is (= [0 3 [2 3]] (m "(a){1,3}" "aaaa"))))

(deftest empty-iterations
  (is (= [0 3 [2 2]] (m "(a*)*b" "aab")))
  (is (= [0 0 [0 0]] (m "(a*)+" "")))
  (is (= [0 1 [1 1]] (m "(a|)*" "a")) "empty iteration after a non-empty one")
  (is (= [0 1 [0 1] nil] (m "(a)|(b)" "ab"))))

(deftest group-captures
  (is (= [0 2 [0 1] [1 2] nil] (m "(a)(b)|(c)" "abc")))
  (is (= [2 3 nil nil [2 3]] (m "(a)(b)|(c)" "xxc"))))

(deftest pattern-errors
  (testing "invalid patterns throw ex-info"
    (is (thrown? clojure.lang.ExceptionInfo (re/compile "(a")))
    (is (thrown? clojure.lang.ExceptionInfo (re/compile "a)")))
    (is (thrown? clojure.lang.ExceptionInfo (re/compile "[a")))
    (is (thrown? clojure.lang.ExceptionInfo (re/compile "a{2,1}")))
    (is (thrown? clojure.lang.ExceptionInfo (re/compile "\\q")))))

(deftest compiled-pattern-reuse
  (let [p (re/compile "(\\d+)-(\\d+)")]
    (is (= 2 (re/group-count p)))
    (is (= {:start 2 :end 7 :groups [[2 3] [4 7]]} (re/match p "x 1-234")))
    (is (nil? (re/match p "none")))
    (is (= {:start 0 :end 3 :groups [[0 1] [2 3]]} (re/match p "1-2")))))

(deftest deep-subjects
  (let [subject (apply str (repeat 10000 \a))]
    (is (= {:start 0 :end 10000 :groups [[9999 10000]]}
           (re/call-with-stack-size (* 256 1024 1024)
                                    #(re/re-match "(a)*" subject))))
    (is (= {:start 0 :end 10000 :groups []}
           (re/call-with-stack-size (* 64 1024 1024)
                                    #(re/re-match ".*" subject))))))

(deftest pathological-but-bounded
  (is (nil? (m "(x+x+)+y" (apply str (repeat 18 \x)))))
  (is (nil? (m "(a|aa)+c" (apply str (repeat 25 \a))))))
