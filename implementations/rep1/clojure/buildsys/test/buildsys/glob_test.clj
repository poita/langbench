(ns buildsys.glob-test
  (:require [buildsys.glob :as glob]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]))

(defn- m? [pattern candidate]
  (glob/matches? (glob/compile-pattern pattern) candidate))

(deftest spec-table
  (testing "matches"
    (doseq [[p c] [["src/*.txt" "src/a.txt"] ["src/*.txt" "src/.txt"]
                   ["src/**" "src/a.txt"] ["src/**" "src/x/y/z.txt"] ["src/**" "src"]
                   ["**/*.txt" "a.txt"] ["**/*.txt" "src/a.txt"] ["**/*.txt" "a/b/c.txt"]
                   ["src/**/t_*.txt" "src/t_1.txt"] ["src/**/t_*.txt" "src/a/b/t_2.txt"]
                   ["src/?.txt" "src/a.txt"] ["src/[ab]*.txt" "src/a1.txt"]
                   ["src/[!ab]*.txt" "src/c.txt"] ["src/[0-9].txt" "src/7.txt"]
                   ["a**b" "axyzb"] ["a**b" "ab"] ["[-a]*" "-x"] ["[a-]*" "-x"]
                   ["[*?]" "?"]]]
      (is (m? p c) (str p " should match " c))))
  (testing "does not match"
    (doseq [[p c] [["src/*.txt" "src/sub/a.txt"] ["src/*.txt" "a.txt"]
                   ["src/**" "other/a.txt"] ["src/**" "srcx"] ["**/*.txt" "a.text"]
                   ["src/**/t_*.txt" "src/t.txt"] ["src/?.txt" "src/ab.txt"]
                   ["src/[ab]*.txt" "src/c.txt"] ["src/[!ab]*.txt" "src/a.txt"]
                   ["src/[0-9].txt" "src/x.txt"] ["a**b" "a/b"]]]
      (is (not (m? p c)) (str p " should not match " c)))))

(deftest empty-components-are-kept
  (is (m? "*" ""))
  (is (m? "**" ""))
  (is (not (m? "?" "")))
  (is (not (m? "*" "a//b")))
  (is (m? "**" "a//b"))
  (is (m? "*/*" "x/"))
  (is (m? "*/*" "/x")))

(deftest malformed-patterns
  (doseq [p ["" "/a" "a/" "a//b" "[" "[]" "[]]" "[!]" "[a" "[z-a]" "a/[b"]]
    (is (nil? (glob/compile-pattern p)) (pr-str p)))
  (doseq [p ["[a-]" "[-a]" "[!a]" "[a-c]"]]
    (is (some? (glob/compile-pattern p)) (pr-str p))))

(deftest literal-prefix
  (is (= "src/" (glob/literal-prefix (glob/compile-pattern "src/*.txt"))))
  (is (= "lib" (glob/literal-prefix (glob/compile-pattern "lib/**"))))
  (is (= "" (glob/literal-prefix (glob/compile-pattern "**/x")))))

;; Property: without `**` components, matching agrees with a regex translation.

(defn- ->regex [pattern]
  (re-pattern
   (apply str (map (fn [c] (case c \* "[^/]*" \? "[^/]" (java.util.regex.Pattern/quote (str c))))
                   pattern))))

(defspec agrees-with-regex 500
  (prop/for-all [p (gen/such-that #(not-any? #{"**"} (str/split % #"/" -1))
                                  (gen/fmap str/join
                                            (gen/vector (gen/elements ["a" "b" "*" "?" "/"]) 1 8)))
                 c (gen/fmap str/join (gen/vector (gen/elements ["a" "b" "/"]) 0 8))]
    (let [compiled (glob/compile-pattern p)]
      (or (nil? compiled)           ; malformed (empty components)
          (= (boolean (re-matches (->regex p) c))
             (glob/matches? compiled c))))))
