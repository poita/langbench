(ns regex.parser-test
  (:require [clojure.test :refer [deftest is testing]]
            [regex.charset :as cs]
            [regex.parser :as p]))

(defn- ast [pattern] (:ast (p/parse pattern)))

(deftest literals-and-sequences
  (is (= [:seq []] (ast "")))
  (is (= [:char 97] (ast "a")))
  (is (= [:seq [[:char 97] [:any] [:bol] [:eol]]] (ast "a.^$")))
  (is (= [:char 32] (ast " "))))

(deftest alternation
  (is (= [:alt [[:char 97] [:seq []]]] (ast "a|")))
  (is (= [:alt [[:seq []] [:seq []] [:seq []]]] (ast "||"))))

(deftest groups-are-numbered-by-open-paren
  (let [{:keys [ast groups]} (p/parse "(a(b))(c)")]
    (is (= 3 groups))
    (is (= [:seq [[:group 1 [:seq [[:char 97] [:group 2 [:char 98]]]]]
                  [:group 3 [:char 99]]]]
           ast)))
  (is (= [:group 1 [:seq []]] (ast "()"))))

(deftest quantifiers
  (is (= [:rep [:char 97] 0 nil] (ast "a*")))
  (is (= [:rep [:char 97] 1 nil] (ast "a+")))
  (is (= [:rep [:char 97] 0 1] (ast "a?")))
  (is (= [:rep [:char 97] 3 3] (ast "a{3}")))
  (is (= [:rep [:char 97] 2 nil] (ast "a{2,}")))
  (is (= [:rep [:char 97] 2 5] (ast "a{2,5}")))
  (is (= [:rep [:char 97] 0 0] (ast "a{0}")))
  (is (= [:rep [:group 1 [:char 97]] 0 nil] (ast "(a)*"))))

(defn- set-of [pattern]
  (let [[kind t] (ast pattern)] (is (= :set kind)) t))

(deftest classes
  (let [t (set-of "[a-c]")]
    (is (every? #(cs/member? t (int %)) "abc"))
    (is (not (cs/member? t (int \d)))))
  (let [t (set-of "[^a-c]")]
    (is (not (cs/member? t (int \b))))
    (is (cs/member? t (int \z))))
  (testing "dash is literal first, last or escaped"
    (is (every? #(cs/member? (set-of "[-a]") (int %)) "-a"))
    (is (every? #(cs/member? (set-of "[a-]") (int %)) "a-"))
    (is (every? #(cs/member? (set-of "[a\\-z]") (int %)) "a-z"))
    (is (not (cs/member? (set-of "[a\\-z]") (int \b)))))
  (testing "caret not first is literal, escapes inside classes"
    (is (cs/member? (set-of "[a^]") (int \^)))
    (is (cs/member? (set-of "[\\]\\\\]") (int \])))
    (is (cs/member? (set-of "[\\]\\\\]") (int \\)))
    (is (cs/member? (set-of "[\\d_]") (int \5)))
    (is (not (cs/member? (set-of "[\\D]") (int \5))))))

(deftest escapes
  (is (cs/member? (set-of "\\d") (int \7)))
  (is (not (cs/member? (set-of "\\d") (int \x))))
  (is (cs/member? (set-of "\\w") (int \_)))
  (is (cs/member? (set-of "\\W") (int \-)))
  (is (cs/member? (set-of "\\s") (int \space)))
  (is (cs/member? (set-of "\\S") (int \a)))
  (is (= [:char 46] (ast "\\.")))
  (is (= [:char 32] (ast "\\ ")))
  (is (= [:char 64] (ast "\\@"))))

(defn- syntax-error? [pattern]
  (try (p/parse pattern) false
       (catch clojure.lang.ExceptionInfo e (= ::p/syntax-error (:type (ex-data e))))))

(deftest invalid-patterns
  (doseq [bad ["(" ")" "a)" "(a" "*" "+a" "a**" "a{2}{3}" "^*" "$+" "a{" "a{,3}" "a{3,2}"
               "a{01}" "a{101}" "[" "[a" "[]" "\\" "\\b" "\\1" "[z-a]" "|*" "(*)" "a{1,2"]]
    (is (syntax-error? bad) (pr-str bad))))
