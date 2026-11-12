(ns regex.parser-test
  (:require [clojure.test :refer [deftest is]]
            [regex.charset :as cs]
            [regex.parser :as p]))

(deftest structure
  (is (= {:ast [:seq [[:char \a] [:char \b]]] :groups 0} (p/parse "ab")))
  (is (= {:ast [:alt [[:char \a] [:seq []]]] :groups 0} (p/parse "a|")))
  (is (= {:ast [:seq []] :groups 0} (p/parse "")))
  (is (= {:ast [:group 1 [:rep [:char \a] 2 nil]] :groups 1} (p/parse "(a{2,})")))
  (is (= [:rep [:any] 0 1] (:ast (p/parse ".?"))))
  (is (= [:rep [:char \a] 3 5] (:ast (p/parse "a{3,5}"))))
  (is (= [:rep [:char \a] 0 0] (:ast (p/parse "a{0}"))))
  (is (= [:seq [[:bol] [:char \a] [:eol]]] (:ast (p/parse "^a$")))))

(deftest group-numbering
  (let [{:keys [ast groups]} (p/parse "((a)(b))(c)")]
    (is (= 4 groups))
    (is (= [:seq [[:group 1 [:seq [[:group 2 [:char \a]] [:group 3 [:char \b]]]]]
                  [:group 4 [:char \c]]]]
           ast))))

(deftest classes
  (let [set (-> (p/parse "[a-c\\]-]") :ast second)]
    (is (every? #(cs/member? set %) "abc]-"))
    (is (not (cs/member? set \d))))
  (let [set (-> (p/parse "[^a]") :ast second)]
    (is (not (cs/member? set \a)))
    (is (cs/member? set \b)))
  (let [set (-> (p/parse "[\\d_]") :ast second)]
    (is (every? #(cs/member? set %) "05_"))
    (is (not (cs/member? set \a))))
  (is (cs/member? (-> (p/parse "[a^]") :ast second) \^)))

(deftest escapes
  (is (= [:char \.] (:ast (p/parse "\\."))))
  (is (= [:char \space] (:ast (p/parse "\\ "))))
  (is (cs/member? (-> (p/parse "\\s") :ast second) \space))
  (is (not (cs/member? (-> (p/parse "\\S") :ast second) \space))))

(deftest errors
  (doseq [bad ["(" ")" "[" "[b-a]" "a{" "a{1" "a{2,1}" "\\n" "a{,2}"]]
    (is (thrown? clojure.lang.ExceptionInfo (p/parse bad)) bad)))
