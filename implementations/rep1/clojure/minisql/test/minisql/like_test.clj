(ns minisql.like-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [minisql.like :refer [like?]]))

(deftest examples
  (is (like? "APPLE" "apple"))
  (is (like? "Ab_c" "ab%"))
  (is (like? "abc" "a_c"))
  (is (not (like? "ac" "a_c")))
  (is (like? "" "%"))
  (is (like? "" ""))
  (is (not (like? "a" "")))
  (is (like? "abcabc" "%abc"))
  (is (like? "aXbXc" "a%b%c"))
  (is (not (like? "É" "é")) "only ASCII letters fold")
  (is (like? "12345" "12%"))
  (is (not (like? "abc" "ab")) "the whole string must match")
  (is (like? "a%b" "a_b") "% in the subject is an ordinary character")
  (is (like? "😀x" "_x") "_ matches one code point"))

(defn- oracle [s p]
  (let [rx (->> (str/lower-case p)
                (map (fn [c] (case c \% ".*" \_ "." (java.util.regex.Pattern/quote (str c)))))
                str/join)]
    (boolean (re-matches (re-pattern (str "(?s)" rx)) (str/lower-case s)))))

(defspec agrees-with-regex-oracle 1000
  (let [chars (gen/elements [\a \b \A \B \% \_ \c])]
    (prop/for-all [s (gen/fmap str/join (gen/vector (gen/elements [\a \b \A \B \c \_ \%]) 0 8))
                   p (gen/fmap str/join (gen/vector chars 0 6))]
      (= (like? s p) (oracle s p)))))
