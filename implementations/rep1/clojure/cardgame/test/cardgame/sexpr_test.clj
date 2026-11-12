(ns cardgame.sexpr-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [cardgame.sexpr :as sx]))

(deftest reads-lists-atoms-and-strings
  (is (= [[(symbol "card") (symbol "A") [(symbol "name") "x y"] 12 -3]]
         (sx/read-all "(card A (name \"x y\") 12 -3)")))
  (is (= [] (sx/read-all "")))
  (is (= [] (sx/read-all "  ; only a comment\n")))
  (is (= [[]] (sx/read-all "()"))))

(deftest symbols-versus-integers
  (let [[a b c d] (first (sx/read-all "(+5 -  1a 007)"))]
    (is (symbol? a))
    (is (symbol? b))
    (is (symbol? c))
    (is (= 7 d))))

(deftest comments-and-whitespace
  (is (= [[(symbol "a") (symbol "b")]]
         (sx/read-all "(a ;comment (with parens\n\t\f\u000B b)")))
  (testing "semicolons inside strings are not comments"
    (is (= [["x;y"]] (sx/read-all "(\"x;y\")")))))

(deftest atoms-end-at-delimiters
  (is (= [[(symbol "a") "b" (symbol "c")]] (sx/read-all "(a\"b\"c)"))))

(deftest rejects-malformed-input
  (doseq [bad ["(a" ")" "(a))" "\"abc" "\"a\nb\"" "(99999999999999999999)"
               "(-9223372036854775809)"]]
    (testing bad
      (is (thrown? clojure.lang.ExceptionInfo (sx/read-all bad)))))
  (is (sx/bad-database? (try (sx/read-all "(") (catch Exception e e)))))

(deftest integer-limits
  (is (= [[Long/MAX_VALUE Long/MIN_VALUE]]
         (sx/read-all "(9223372036854775807 -9223372036854775808)"))))

(deftest canonical-printing
  (is (= "(a (b \"c\") 12 -4)" (sx/print-form (first (sx/read-all "(a   (b\n\"c\")\t12 -4)"))))))

(def ^:private form-gen
  (gen/recursive-gen
   (fn [inner] (gen/vector inner 0 4))
   (gen/one-of [(gen/fmap symbol (gen/elements ["card" "name" "x-1" "ABC-123"]))
                (gen/large-integer* {:min -1000 :max 1000})
                (gen/fmap #(apply str %) (gen/vector (gen/elements (seq "abc ;()")) 0 6))])))

(defspec print-then-read-roundtrips 100
  (prop/for-all [forms (gen/vector form-gen 0 4)]
    ;; strings containing parentheses etc. survive, since they stay quoted
    (let [text (clojure.string/join " " (map sx/print-form forms))]
      (= forms (sx/read-all text)))))
