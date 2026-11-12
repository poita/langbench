(ns jsonschema.regex-test
  (:require [clojure.test :refer [deftest is testing are]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [jsonschema.regex :as re]))

(defn- m? [pattern s] (re/search? (re/compile-pattern pattern) s))

(deftest literals-and-search
  (is (m? "bar" "foobarbaz"))
  (is (not (m? "bar" "foobaz")))
  (is (m? "" "anything"))
  (is (m? "" "")))

(deftest anchors
  (is (m? "^abc$" "abc"))
  (is (not (m? "^abc$" "xabc")))
  (is (not (m? "^a$" "a\n")))
  (is (m? "^$" ""))
  (is (not (m? "a^b" "a^b")))
  (is (m? "b$" "ab")))

(deftest alternation-and-groups
  (is (m? "^(a|b)c$" "bc"))
  (is (m? "^(?:foo|bar)+$" "foobarfoo"))
  (is (not (m? "^(foo|bar)+$" "foobaz")))
  (is (m? "^(a|)b$" "b"))
  (is (m? "^()$" "")))

(deftest quantifiers
  (are [p s expected] (= expected (m? p s))
    "^a*$" "" true
    "^a+$" "" false
    "^ab?c$" "ac" true
    "^a{3}$" "aaa" true
    "^a{3}$" "aaaa" false
    "^a{2,}$" "aaaaa" true
    "^a{2,}$" "a" false
    "^a{2,3}$" "aaaa" false
    "^a{0}b$" "b" true
    "^a{,3}$" "a{,3}" true
    "^a{x}$" "a{x}" true
    "^a{1,2" "a{1,2" true
    "^a+?$" "aaa" true
    "^(a|ab)(c|bcd)(d*)$" "abcd" true))

(deftest counted-repetition-expansion
  (is (m? "^(ab){50}$" (apply str (repeat 50 "ab"))))
  (is (not (m? "^(ab){50}$" (apply str (repeat 49 "ab")))))
  (is (m? "^a{0,100}$" (apply str (repeat 100 "a"))))
  (is (not (m? "^a{0,100}$" (apply str (repeat 101 "a"))))))

(deftest dot
  (is (m? "^.$" "x"))
  (is (m? "^.$" "💩"))
  (is (not (m? "^.$" "\n")))
  (is (not (m? "^.$" "\r")))
  (is (not (m? "^.$" "\u2028")))
  (is (not (m? "^.$" "\u2029")))
  (is (m? "^.$" "\u0085")))

(deftest classes
  (are [p s expected] (= expected (m? p s))
    "^[abc]+$" "abcabc" true
    "^[a-c]+$" "abd" false
    "^[^a-c]+$" "xyz" true
    "^[^a-c]+$" "xaz" false
    "^[a-]$" "-" true
    "^[-a]$" "-" true
    "^[a\\-z]$" "-" true
    "^[\\d-x]+$" "1-x" true
    "^[\\]]$" "]" true
    "^[]a]$" "a" false
    "^[^]$" "a" true
    "^[\\w.]+$" "a.b_c" true
    "^[\\b]$" "\b" true
    "^[\\D]$" "5" false
    "^[\\S\\s]$" "\n" true
    "^[^\\s]+$" "ab" true
    "^[a-z\\d]+$" "a1" true))

(deftest class-escapes
  (are [p s expected] (= expected (m? p s))
    "^\\d+$" "0123456789" true
    "^\\d$" "٣" false
    "^\\D$" "a" true
    "^\\w+$" "aZ_9" true
    "^\\w$" "é" false
    "^\\W$" "é" true
    "^\\s+$" " \t\n\u00a0\u1680\u2003\u202f\u205f\u3000\ufeff" true
    "^\\s$" "\u200b" false
    "^\\S$" "x" true))

(deftest character-escapes
  (are [p s expected] (= expected (m? p s))
    "^\\n\\r\\t\\f\\v$" "\n\r\t\f\u000b" true
    "^\\0$" "\u0000" true
    "^\\x41$" "A" true
    "^\\u0041$" "A" true
    "^\\ud83d\\udca9$" "💩" true
    "^\\cJ$" "\n" true
    "^\\.$" "." true
    "^\\.$" "a" false
    "^\\\\$" "\\" true
    "^\\/$" "/" true
    "^\\-$" "-" true
    "^\\*\\+\\?\\(\\)\\[\\]\\{\\}\\|\\^\\$$" "*+?()[]{}|^$" true))

(deftest word-boundaries
  (is (m? "\\bcat\\b" "a cat sat"))
  (is (not (m? "\\bcat\\b" "concat")))
  (testing "boundaries are ASCII-only"
    (is (m? "\\bcat\\b" "écat ")))
  (is (m? "\\Bcat" "concat"))
  (is (not (m? "\\Bcat" "cat")))
  (is (m? "^\\b$|^\\B$" "")))

(deftest unicode-subjects
  (is (m? "^.{1}$" "💩"))
  (is (m? "^.{2}$" "e\u0301"))
  (is (m? "^[💩]$" "💩"))
  (is (m? "^[\\u0000-\\uffff]$" "u")))

(deftest no-exponential-blowup
  (testing "classic catastrophic patterns finish quickly"
    (let [s (str (apply str (repeat 5000 "a")) "b")]
      (is (not (m? "^(a+)+$" s)))
      (is (not (m? "^(a*)*$" s)))
      (is (not (m? "^(a|aa)+$" s)))
      (is (not (m? "(x+x+)+y" (apply str (repeat 5000 "x"))))))))

(deftest syntax-errors
  (doseq [bad ["(" "(a" "a)" "[a" "*" "+a" "a**" "\\" "(?=a)" "(?<n>a)" "a{3,2}"]]
    (is (thrown? clojure.lang.ExceptionInfo (re/compile-pattern bad)) (pr-str bad))))

;; ---------------------------------------------------------------------------
;; Property: agrees with java.util.regex on a common, unambiguous subset.

(def ^:private gen-atom
  (gen/one-of [(gen/elements ["a" "b" "." "[ab]" "[^a]" "\\w"])]))

(def ^:private gen-pattern
  (gen/recursive-gen
   (fn [inner]
     (gen/one-of
      [(gen/fmap (fn [xs] (apply str xs)) (gen/vector inner 1 3))
       (gen/fmap (fn [[a b]] (str "(?:" a "|" b ")")) (gen/tuple inner inner))
       (gen/fmap (fn [[a q]] (str "(?:" a ")" q)) (gen/tuple inner (gen/elements ["*" "+" "?" "{2}" "{1,2}" "{0,2}" "*?" "+?"])))]))
   gen-atom))

(defspec agrees-with-java-regex 500
  (prop/for-all [pattern gen-pattern
                 anchored? gen/boolean
                 s (gen/fmap #(apply str %) (gen/vector (gen/elements [\a \b \c]) 0 8))]
    (let [pat (if anchored? (str "^(?:" pattern ")$") pattern)
          expected (boolean (re-find (re-pattern pat) s))]
      (= expected (m? pat s)))))
