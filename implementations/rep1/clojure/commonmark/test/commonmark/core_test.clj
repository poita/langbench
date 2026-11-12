(ns commonmark.core-test
  (:require [clojure.edn :as edn]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [commonmark.core :as cm]))

(defn- html= [expected md]
  (= expected (cm/markdown->html md)))

(deftest worked-examples
  (testing "headings, emphasis, links, lists, quotes and code"
    (is (= (str "<h1>Title</h1>\n"
                "<p>Some <em>emphasis</em>, <strong>strong</strong>, <code>code</code> and a "
                "<a href=\"/my%20uri\" title=\"t&quot;x\">link</a>.</p>\n"
                "<ul>\n<li>one</li>\n<li>two\n<ul>\n<li>nested</li>\n</ul>\n</li>\n</ul>\n"
                "<ol>\n<li>\n<p>a</p>\n<p>b</p>\n</li>\n<li>\n<p>c</p>\n</li>\n</ol>\n"
                "<blockquote>\n<p>quote<br />\nline<br />\n\tlazy</p>\n</blockquote>\n"
                "<pre><code>code &lt;b&gt;\n</code></pre>\n")
           (cm/markdown->html
            (str "# Title #\n\n"
                 "Some *emphasis*, **strong**, `code` and a [link](</my uri> \"t\\\"x\").\n\n"
                 "- one\n- two\n  - nested\n\n"
                 "1. a\n\n   b\n2. c\n\n"
                 "> quote  \n> line\\\n\tlazy\n\n"
                 "    code <b>\n")))))
  (testing "rule of three, intraword underscores, images, autolinks and entities"
    (is (= (str "<p><em>foo<strong>bar</strong>baz</em> <em>a_b</em> <strong>a <em>b</em> c</strong> "
                "<img src=\"/i.png\" alt=\"alt x y\" />\n"
                "<a href=\"http://a.b/?x=1&amp;y=2\">http://a.b/?x=1&amp;y=2</a> &amp;copy; AB� *lit* a<br />\nb</p>\n")
           (cm/markdown->html
            (str "*foo**bar**baz* _a_b_ **a *b* c** ![alt *x* `y`](/i.png)\n"
                 "<http://a.b/?x=1&y=2> &amp;copy; &#65;&#x42;&#0; \\*lit\\* a\\\nb")))))
  (testing "loose and tight lists, fenced code in items, setext headings"
    (is (= (str "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<pre><code class=\"language-py\">x = &quot;&lt;&gt;&quot;\n</code></pre>\n</li>\n"
                "<li>\n<p>c</p>\n<p>d</p>\n</li>\n</ul>\n<ul>\n<li>e</li>\n</ul>\n<hr />\n<h2>Foo</h2>\n"
                "<p><a href=\"\">j</a> <a href=\"/x\" title=\"\">k</a> <a href=\"\"></a></p>\n")
           (cm/markdown->html
            (str "- a\n- ```py\n  x = \"<>\"\n  ```\n- c\n\n  d\n* e\n***\nFoo\n---\n"
                 "[j](javascript:alert(1)) [k](/x \"\") [](<>)"))))))

(deftest api
  (is (= "" (cm/markdown->html "")))
  (is (= "<p>a</p>\n" (cm/markdown->html "a")))
  (let [doc (cm/parse "# h\n\n*x*")]
    (is (= :document (:type doc)))
    (is (= [:heading :paragraph] (mapv :type (:children doc))))
    (is (= [[:start :emph] [:text "x"] [:end :emph]] (:inlines (second (:children doc)))))
    (is (= "<h1>h</h1>\n<p><em>x</em></p>\n" (cm/render doc)))))

;; ---------------------------------------------------------------------------
;; Examples taken from the CommonMark specification, and golden files
;; ---------------------------------------------------------------------------

(deftest spec-examples
  (let [examples (edn/read-string (slurp (io/file "test/golden/spec_examples.edn")))]
    (is (= 473 (count examples)))
    (doseq [{:keys [n section markdown html]} examples]
      (is (= html (cm/markdown->html markdown))
          (str "spec example " n " (" section ")")))))

(defn- normalize
  "The comparison of the test runner: trailing whitespace of each line and
  trailing newlines are ignored."
  [s]
  (str/replace (str/join "\n" (map str/trimr (str/split s #"\n" -1))) #"\n+\z" ""))

(deftest golden-files
  (let [inputs (->> (.listFiles (io/file "test/golden"))
                    (filter #(str/ends-with? (.getName ^java.io.File %) ".in"))
                    (sort-by #(.getName ^java.io.File %)))]
    (is (> (count inputs) 50))
    (doseq [^java.io.File in inputs]
      (let [expected (slurp (io/file (str/replace (.getPath in) #"\.in$" ".out")))]
        (is (= (normalize expected) (normalize (cm/markdown->html (slurp in))))
            (.getName in))))))

;; ---------------------------------------------------------------------------
;; Behaviours worth pinning down individually
;; ---------------------------------------------------------------------------

(deftest tabs
  (is (html= "<pre><code>foo\tbaz\t\tbim\n</code></pre>\n" "\tfoo\tbaz\t\tbim\n"))
  (is (html= "<ul>\n<li>\n<p>foo</p>\n<pre><code>  bar\n</code></pre>\n</li>\n</ul>\n" "- foo\n\n\t\tbar\n"))
  (is (html= "<blockquote>\n<pre><code>  foo\n</code></pre>\n</blockquote>\n" ">\t\tfoo\n")))

(deftest tight-lists-and-thematic-breaks
  (is (html= "<ul>\n<li>\n<hr />\n</li>\n<li>b</li>\n</ul>\n" "- ***\n- b")
      "a thematic break inside an item does not make the list loose")
  (is (html= "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n" "- a\n- b\n")))

(deftest links-and-images
  (is (html= "<p><a href=\"/d\">x <a href=\"/b\">a</a> <img src=\"/k\" alt=\"i [q] j\" /> y</a></p>\n"
             "[x [a](/b) ![i [q] j](/k) y](/d)")
      "cmark's single link_closed flag, not the specification's deactivation of openers")
  (is (html= "<p>[x <a href=\"/b\">a</a> <img src=\"/j\" alt=\"i\" /> y](/d)</p>\n"
             "[x [a](/b) ![i](/j) y](/d)"))
  (is (html= "<p>[a](/my uri)</p>\n" "[a](/my uri)"))
  (is (html= "<p><a href=\"/a%20b%22\">a</a></p>\n" "[a](</a b\">)"))
  (is (html= "<p><a href=\"data:image/png;base64,AA\">a</a> <a href=\"\">b</a></p>\n"
             "[a](data:image/png;base64,AA) [b](vbscript:x)")))

(deftest raw-html-like-text-is-escaped
  (is (html= "<p>1 &lt; 2 &amp;&amp; 3 &gt; 2 &lt;3</p>\n" "1 < 2 && 3 > 2 <3")))

;; ---------------------------------------------------------------------------
;; Robustness
;; ---------------------------------------------------------------------------

(deftest deep-nesting
  (testing "block quotes and lists 300 deep"
    (let [html (cm/markdown->html (str (apply str (repeat 300 "> ")) "x"))]
      (is (= 300 (count (re-seq #"<blockquote>" html)))))
    (let [html (cm/markdown->html (str/join "\n" (map #(str (apply str (repeat % "  ")) "- a") (range 150))))]
      (is (= 150 (count (re-seq #"<ul>" html))))))
  (testing "thousands of nested inlines"
    (let [n 5000
          html (cm/markdown->html (str (apply str (repeat n "[")) "a" (apply str (repeat n "](/u)"))))]
      (is (str/includes? html "<a href=\"/u\">")))
    (let [html (cm/markdown->html (str (apply str (repeat 5000 "*a ")) "b" (apply str (repeat 5000 " c*"))))]
      (is (= 5000 (count (re-seq #"<em>" html)))))))

(deftest linear-time-on-pathological-input
  (testing "unmatched brackets, emphasis runs and backtick runs"
    (doseq [md [(str (apply str (repeat 20000 "[")) (apply str (repeat 20000 "]")))
                (apply str (repeat 50000 "*a "))
                (apply str (repeat 50000 "**a_ "))
                (apply str (for [i (range 20000)] (str (apply str (repeat (inc (mod i 40)) "`")) " ")))
                (apply str (repeat 20000 "[a](b \""))]]
      (let [start (System/nanoTime)
            _ (cm/markdown->html md)
            ms (/ (- (System/nanoTime) start) 1e6)]
        (is (< ms 5000) (str "took " ms " ms"))))))
