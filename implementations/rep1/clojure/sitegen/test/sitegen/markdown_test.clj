(ns sitegen.markdown-test
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [sitegen.markdown :as md]
            [sitegen.markdown.text :as text]))

(defn- fixtures
  "The pairs [name markdown expected-html] found in test-resources/markdown.
  The expected files were produced by cmark 0.31.2 with default options."
  []
  (let [dir (io/file (io/resource "markdown"))]
    (for [f (sort (.listFiles dir))
          :let [n (.getName f)]
          :when (str/ends-with? n ".md")
          :let [base (subs n 0 (- (count n) 3))]]
      [base (slurp f) (slurp (io/file dir (str base ".html")))])))

(deftest cmark-fixtures
  (let [cases (fixtures)]
    (is (>= (count cases) 20) "fixtures are present")
    (doseq [[name src expected] cases]
      (testing name
        (is (= expected (md/->html src)))))))

(deftest blocks
  (testing "empty and blank input"
    (is (= "" (md/->html "")))
    (is (= "" (md/->html "\n  \n\t\n"))))
  (testing "paragraphs"
    (is (= "<p>a\nb</p>\n<p>c</p>\n" (md/->html "a\nb\n\nc"))))
  (testing "headings"
    (is (= "<h1>Hi</h1>\n" (md/->html "# Hi #")))
    (is (= "<h2>Hi</h2>\n" (md/->html "Hi\n--")))
    (is (= "<p>####### x</p>\n" (md/->html "####### x"))))
  (testing "thematic break beats list item"
    (is (= "<hr />\n" (md/->html "***"))))
  (testing "code"
    (is (= "<pre><code>a\n</code></pre>\n" (md/->html "    a")))
    (is (= "<pre><code class=\"language-clj\">(+ 1 2)\n</code></pre>\n" (md/->html "```clj\n(+ 1 2)\n```")))
    (is (= "<pre><code>unclosed\n</code></pre>\n" (md/->html "```\nunclosed"))))
  (testing "lists"
    (is (= "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n" (md/->html "- a\n- b")))
    (is (= "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ul>\n" (md/->html "- a\n\n- b")))
    (is (= "<ol start=\"3\">\n<li>x</li>\n</ol>\n" (md/->html "3. x")))
    (is (= "<ul>\n<li></li>\n</ul>\n" (md/->html "-"))))
  (testing "block quotes"
    (is (= "<blockquote>\n<p>a\nb</p>\n</blockquote>\n" (md/->html "> a\nb")))))

(deftest inlines
  (is (= "<p><em>a</em> <strong>b</strong></p>\n" (md/->html "*a* **b**")))
  (is (= "<p>a_b_c</p>\n" (md/->html "a_b_c")))
  (is (= "<p><code>a b</code></p>\n" (md/->html "`` a b ``")))
  (is (= "<p><a href=\"/u\" title=\"t\">x</a></p>\n" (md/->html "[x](/u \"t\")")))
  (is (= "<p><img src=\"/i\" alt=\"a b\" /></p>\n" (md/->html "![a *b*](/i)")))
  (is (= "<p>a<br />\nb</p>\n" (md/->html "a  \nb")))
  (is (= "<p>*not em*</p>\n" (md/->html "\\*not em\\*")))
  (is (= "<p>&amp; &lt; A</p>\n" (md/->html "&amp; &lt; &#65;")))
  (is (= "<p><a href=\"mailto:a@b.co\">a@b.co</a></p>\n" (md/->html "<a@b.co>"))))

(deftest text-helpers
  (testing "escape-html"
    (is (= "&amp;&lt;&gt;&quot;'" (text/escape-html "&<>\"'")))
    (is (= "plain" (text/escape-html "plain"))))
  (testing "href"
    (is (= "/a%20b" (text/href "/a b")))
    (is (= "" (text/href "JavaScript:alert(1)")))
    (is (= "data:image/png;base64,AA" (text/href "data:image/png;base64,AA")))
    (is (= "/%C3%BC&amp;&#x27;" (text/href "/ü&'")))
    (is (= "/a%b" (text/href "/a%b")) "existing percent signs are copied")
    (is (= "/%41" (text/href "/%41"))))
  (testing "decode-entities"
    (is (= "&<>\"AB\uFFFD" (text/decode-entities "&amp;&lt;&gt;&quot;&#65;&#x42;&#0;")))
    (is (= "&foo; &#12345678;" (text/decode-entities "&foo; &#12345678;"))))
  (testing "unescape-backslashes"
    (is (= "*a\\b" (text/unescape-backslashes "\\*a\\b")))))

(deftest deep-nesting
  (testing "deeply nested block quotes and emphasis do not overflow the stack"
    (is (str/includes? (md/->html (str (apply str (repeat 300 ">")) " x")) "x"))
    (is (str/includes? (md/->html (str (apply str (repeat 3000 "*a ")) "b" (apply str (repeat 3000 " c*"))))
                       "<em>"))))

;; ---------------------------------------------------------------------------
;; Properties

(def ^:private fragment
  (gen/elements ["a" "b c" "*" "**" "_" "`" "\\" "&amp;" "[" "]" "(" ")" "![" "# " "- " "1. " "> "
                 "    " "\t" "\n" "\n\n" "```" "~~~" "---" "===" "<http://x.y>" "  \n" "é" "\"" "'"]))

(def ^:private document (gen/fmap str/join (gen/vector fragment 0 40)))

(defspec conversion-is-total-and-newline-terminated 300
  (prop/for-all [src document]
    (let [html (md/->html src)]
      (or (= "" html) (str/ends-with? html "\n")))))

(defspec plain-text-is-one-paragraph 200
  (prop/for-all [words (gen/vector (gen/fmap str/join (gen/vector (gen/elements (seq "abcxyz019")) 1 8)) 1 10)]
    (let [s (str/join " " words)]
      (= (str "<p>" s "</p>\n") (md/->html s)))))

(defspec html-metacharacters-never-leak 200
  (prop/for-all [src (gen/fmap str/join (gen/vector (gen/elements ["<" ">" "&" "\"" "x" " " "3"]) 0 30))]
    ;; The only `<` and `>` in the output of such input belong to the tags
    ;; the converter itself emits, so stripping tags leaves no raw `<`.
    (let [html (md/->html (str "x " src))
          stripped (str/replace html #"</?p>" "")]
      (and (not (str/includes? stripped "<"))
           (not (str/includes? stripped ">"))))))
