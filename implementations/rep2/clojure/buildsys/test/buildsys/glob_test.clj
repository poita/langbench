(ns buildsys.glob-test
  (:require [buildsys.glob :as glob]
            [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]))

(defn- m? [pat s] (glob/matches? (glob/compile-pattern pat) s))

(deftest spec-table
  (testing "matches"
    (doseq [[p s] [["src/*.txt" "src/a.txt"] ["src/*.txt" "src/.txt"]
                   ["src/**" "src/a.txt"] ["src/**" "src/x/y/z.txt"] ["src/**" "src"]
                   ["**/*.txt" "a.txt"] ["**/*.txt" "src/a.txt"] ["**/*.txt" "a/b/c.txt"]
                   ["src/**/t_*.txt" "src/t_1.txt"] ["src/**/t_*.txt" "src/a/b/t_2.txt"]
                   ["src/?.txt" "src/a.txt"] ["src/[ab]*.txt" "src/a1.txt"]
                   ["src/[!ab]*.txt" "src/c.txt"] ["src/[0-9].txt" "src/7.txt"]
                   ["a**b" "axyzb"] ["a**b" "ab"] ["[-a]*" "-x"] ["[a-]*" "-x"]]]
      (is (m? p s) (str p " should match " s))))
  (testing "does not match"
    (doseq [[p s] [["src/*.txt" "src/sub/a.txt"] ["src/*.txt" "a.txt"]
                   ["src/**" "other/a.txt"] ["src/**" "srcx"] ["**/*.txt" "a.text"]
                   ["src/**/t_*.txt" "src/t.txt"] ["src/?.txt" "src/ab.txt"]
                   ["src/[ab]*.txt" "src/c.txt"] ["src/[!ab]*.txt" "src/a.txt"]
                   ["src/[0-9].txt" "src/x.txt"] ["a**b" "a/b"]]]
      (is (not (m? p s)) (str p " should not match " s)))))

(deftest candidates-keep-empty-components
  (is (m? "*" ""))
  (is (m? "**" ""))
  (is (not (m? "?" "")))
  (is (not (m? "*" "a//b")))
  (is (m? "a/**/b" "a//b"))
  (is (not (m? "*" "x/"))))

(deftest malformed-patterns
  (doseq [p ["" "/a" "a/" "a//b" "[" "[]" "[!]" "[b-a]" "a/[x"]]
    (is (nil? (glob/compile-pattern p)) (pr-str p)))
  (testing "range edge cases"
    (is (some? (glob/compile-pattern "[a-]")))
    (is (some? (glob/compile-pattern "[-a]")))
    (is (some? (glob/compile-pattern "[*?]")))))

(deftest literal-prefix
  (is (= "src/" (glob/literal-prefix "src/*.txt")))
  (is (= "" (glob/literal-prefix "**/x")))
  (is (= "lib" (glob/literal-prefix "lib/**")) "`**` may match zero components")
  (is (= "a/b.txt" (glob/literal-prefix "a/b.txt"))))

(def ^:private seg (gen/fmap #(apply str %) (gen/vector (gen/elements "abc._-+") 1 4)))

(defspec literal-path-matches-itself 100
  (prop/for-all [parts (gen/vector seg 1 4)]
    (let [p (clojure.string/join "/" parts)]
      (and (glob/matches? (glob/compile-pattern p) p)
           (glob/matches? (glob/compile-pattern "**") p)))))

(defspec literal-prefix-is-a-prefix-of-every-match 100
  (prop/for-all [parts (gen/vector seg 1 4)
                 star-at (gen/choose 0 3)]
    (let [pat (clojure.string/join "/" (map-indexed (fn [i s] (if (= i star-at) "*" s)) parts))
          path (clojure.string/join "/" (map-indexed (fn [i s] (if (= i star-at) (str s "x") s)) parts))]
      (or (not (glob/matches? (glob/compile-pattern pat) path))
          (.startsWith ^String path (glob/literal-prefix pat))))))
