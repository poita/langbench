(ns regex.core-test
  (:require [clojure.test :refer [deftest is testing are]]
            [regex.core :as re]))

(defn- fm [pattern s] (re/find-match (re/compile pattern) s))
(defn- fmt [pattern s] (let [m (fm pattern s)] (when m (select-keys m [:start :end]))))

(deftest basic-matching
  (is (= {:start 1 :end 3 :groups []} (fm "bc" "abcd")))
  (is (nil? (fm "x" "abc")))
  (is (= {:start 0 :end 0 :groups []} (fm "" "")))
  (is (= {:start 0 :end 0 :groups []} (fm "a*" "bbb")))
  (is (= {:start 0 :end 1 :groups []} (fm "." " x")))
  (is (nil? (fm "." "")))
  (is (= [0 3] ((juxt :start :end) (fm "\\w+" "ab_ cd")))))

(deftest anchors
  (is (nil? (fm "a^b" "ab")))
  (is (= [0 1] ((juxt :start :end) (fm "^a" "aa"))))
  (is (nil? (fm "^b" "ab")))
  (is (= [1 2] ((juxt :start :end) (fm "a$" "aa"))))
  (is (= {:start 2 :end 2 :groups []} (fm "$" "ab")))
  (is (nil? (fm "^$" "a")))
  (is (some? (fm "^$" ""))))

(deftest spec-examples
  (is (= {:start 0 :end 4 :groups [[0 1] [1 4] [4 4]]} (fm "(a|ab)(c|bcd)(d*)" "abcd")))
  (is (= {:start 0 :end 4 :groups [[0 4]]} (fm "^(a+)+$" "aaaa")))
  (is (nil? (fm "^(a+)+$" "aaab")))
  (is (= {:start 0 :end 2 :groups [[1 2] [0 1]]} (fm "(a|(b))+" "ba")))
  (is (= {:start 0 :end 2 :groups [[1 2] [1 2]]} (fm "(a|(b))+" "ab")))
  (is (= [1 6] ((juxt :start :end) (fm "[^a-c]\\d{2,3}x?" "zz123xx"))))
  (is (nil? (fm "[^a-c]\\d{2,3}x?" "abc9")))
  (is (= {:start 0 :end 3 :groups [[2 2]]} (fm "(a*)*b" "aab")))
  (is (nil? (fm "x$|^(y)?z" "xz")))
  (is (= {:start 1 :end 3 :groups [nil [1 2] [2 3]]} (fm "(a){0}b|(c)?(d)" "xcd")))
  (is (= {:start 1 :end 2 :groups [nil nil nil]} (fm "(a){0}b|(c)?(d)" "xb"))))

(deftest ordered-choice-and-greed
  (is (= [0 1] ((juxt :start :end) (fm "a|ab" "ab"))))
  (is (= [0 3] ((juxt :start :end) (fm "a*" "aaa"))))
  (is (= {:start 0 :end 3 :groups [[0 2]]} (fm "(a+)a" "aaa")))
  (is (= [0 2] ((juxt :start :end) (fm "a{2,3}" "aa"))))
  (is (= [0 3] ((juxt :start :end) (fm "a{2,3}" "aaaa"))))
  (is (= [0 1] ((juxt :start :end) (fm "a{0}b?a" "a")))))

(deftest empty-iterations
  (is (= {:start 0 :end 0 :groups [[0 0]]} (fm "(a*){3}" "")))
  (is (= {:start 0 :end 2 :groups [[2 2]]} (fm "(a*)*" "aa")))
  (is (= {:start 0 :end 0 :groups [[0 0]]} (fm "(|a)+" "a")))
  (is (= {:start 0 :end 1 :groups [[1 1]]} (fm "(a|)+" "a"))))

(deftest unset-groups
  (is (= {:start 0 :end 1 :groups [[0 1] nil]} (fm "(a)|(b)" "a")))
  (is (= {:start 0 :end 1 :groups [nil [0 1]]} (fm "(a)|(b)" "b"))))

(deftest deep-subjects-do-not-overflow-the-stack
  (let [s (apply str (repeat 200000 \a))]
    (is (= [0 200000] ((juxt :start :end) (fm ".*" s))))
    (is (= [0 200000] ((juxt :start :end) (fm "(a)*" s))))
    (is (= {:start 0 :end 200000 :groups [[199999 200000]]} (fm "(a)*" s)))))

(deftest text-helpers
  (is (= {:text "abcd" :groups ["a" "bcd" ""]}
         (re/match-text (re/compile "(a|ab)(c|bcd)(d*)") "abcd")))
  (is (= {:text "a" :groups ["a" nil]} (re/match-text (re/compile "(a)|(b)") "a")))
  (is (true? (re/matches? (re/compile "b") "abc")))
  (is (false? (re/matches? (re/compile "x") "abc")))
  (is (= 2 (re/group-count (re/compile "(a)(b)")))))

(deftest pathological-patterns-terminate
  (is (nil? (fm "(a*)*b" (apply str (repeat 25 \a)))))
  (is (nil? (fm "(a|aa)+c" (apply str (repeat 25 \a)))))
  (is (nil? (fm "a*b" (apply str (repeat 1000 \a))))))

(deftest invalid-pattern-throws
  (is (thrown? clojure.lang.ExceptionInfo (re/compile "(a"))))
