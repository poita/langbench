(ns sitegen.content-test
  (:require [clojure.test :refer [deftest is testing]]
            [sitegen.content :as content]))

(deftest front-matter-splitting
  (testing "the body is everything after the closing line, verbatim"
    (is (= ["a = 1" "body\n\nmore\n"] (content/split-front-matter "+++\na = 1\n+++\nbody\n\nmore\n"))))
  (testing "a closing +++ that is the last line gives an empty body"
    (is (= ["a = 1" ""] (content/split-front-matter "+++\na = 1\n+++")))
    (is (= ["a = 1" ""] (content/split-front-matter "+++\na = 1\n+++\n"))))
  (testing "empty front matter"
    (is (= ["" "x"] (content/split-front-matter "+++\n+++\nx"))))
  (testing "only a whole +++ line closes the front matter"
    (is (= ["t = \"+++\"\nu = \"a\"" "+++ x\n++++\n+++\n"]
           (content/split-front-matter "+++\nt = \"+++\"\nu = \"a\"\n+++\n+++ x\n++++\n+++\n")))
    (is (= ["a = \"x +++\"" "b"] (content/split-front-matter "+++\na = \"x +++\"\n+++\nb"))))
  (testing "malformed files"
    (is (thrown? clojure.lang.ExceptionInfo (content/split-front-matter "no front matter")))
    (is (thrown? clojure.lang.ExceptionInfo (content/split-front-matter "+++\na = 1\n")))
    (is (thrown? clojure.lang.ExceptionInfo (content/split-front-matter "++++\n+++\n")))))

(deftest posts
  (testing "defaults"
    (is (= {:title "T" :date "2024-01-02" :slug "my-post" :tags [] :draft false :body "Hi\n"}
           (content/parse-post "my-post.md" "+++\ntitle = \"T\"\ndate = \"2024-01-02\"\n+++\nHi\n"))))
  (testing "explicit slug, draft flag and tags without duplicates"
    (is (= {:title "T" :date "2024-01-02" :slug "s" :tags ["b" "a" "B"] :draft true :body ""}
           (content/parse-post "x.md" (str "+++\ntitle = \"T\"\ndate = \"2024-01-02\"\nslug = \"s\"\n"
                                           "draft = true\ntags = [\"b\", \"a\", \"b\", \"B\"]\n+++\n")))))
  (testing "invalid front matter is reported with the file name"
    (doseq [text ["+++\ndate = \"2024-01-02\"\n+++\n"
                  "+++\ntitle = \"T\"\n+++\n"
                  "+++\ntitle = \"T\"\ndate = \"yesterday\"\n+++\n"
                  "+++\ntitle = 1\ndate = \"2024-01-02\"\n+++\n"]]
      (let [e (try (content/parse-post "bad.md" text) nil (catch clojure.lang.ExceptionInfo e e))]
        (is (some? e))
        (is (re-find #"bad\.md" (ex-message e)))))))

(deftest pages
  (is (= {:title "About" :slug "about" :draft false :body "# About\n"}
         (content/parse-page "about.md" "+++\ntitle = \"About\"\n+++\n# About\n")))
  (is (= "custom" (:slug (content/parse-page "about.md" "+++\ntitle = \"A\"\nslug = \"custom\"\n+++\n")))))
