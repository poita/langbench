(ns commonmark.html-test
  (:require [clojure.test :refer [deftest is testing]]
            [commonmark.html :as html]))

(defn- inlines->html [events]
  (str (html/render-inlines! (StringBuilder.) events)))

(deftest inline-rendering
  (is (= "a &lt; b" (inlines->html [[:text "a < b"]])))
  (is (= "<code>&amp;</code>" (inlines->html [[:code "&"]])))
  (is (= "a\nb<br />\nc" (inlines->html [[:text "a"] [:softbreak] [:text "b"] [:linebreak] [:text "c"]])))
  (is (= "<em>a</em><strong>b</strong>"
         (inlines->html [[:start :emph] [:text "a"] [:end :emph]
                         [:start :strong] [:text "b"] [:end :strong]])))
  (is (= "<a href=\"/a%20b\" title=\"t&quot;\">x</a>"
         (inlines->html [[:start :link {:destination "/a b" :title "t\""}] [:text "x"] [:end :link]])))
  (is (= "<a href=\"\" title=\"\">x</a>"
         (inlines->html [[:start :link {:destination "javascript:x" :title ""}] [:text "x"] [:end :link]]))))

(deftest image-alt-text
  (is (= "<img src=\"/i.png\" alt=\"a b &lt;c&gt; d\" title=\"T\" />"
         (inlines->html [[:start :image {:destination "/i.png" :title "T"}]
                         [:text "a "]
                         [:start :emph] [:text "b"] [:end :emph]
                         [:text " "] [:code "<c>"] [:softbreak] [:text "d"]
                         [:end :image]])))
  (testing "nested links and images contribute only their descendants"
    (is (= "<img src=\"/o\" alt=\"x y z\" />"
           (inlines->html [[:start :image {:destination "/o" :title nil}]
                           [:text "x "]
                           [:start :link {:destination "/l" :title nil}] [:text "y"] [:end :link]
                           [:text " "]
                           [:start :image {:destination "/i" :title "t"}] [:text "z"] [:end :image]
                           [:end :image]])))))

(deftest block-rendering
  (let [doc {:type :document
             :children [{:type :heading :level 2 :inlines [[:text "T"]]}
                        {:type :thematic-break}
                        {:type :code-block :info "language-x y" :literal "a<b\n"}
                        {:type :code-block :info "clj" :literal ""}
                        {:type :list :ordered? true :start 3 :tight? true
                         :children [{:type :list-item
                                     :children [{:type :paragraph :inlines [[:text "a"]]}]}]}
                        {:type :list :ordered? false :start 0 :tight? false
                         :children [{:type :list-item
                                     :children [{:type :paragraph :inlines [[:text "b"]]}]}
                                    {:type :list-item :children []}]}
                        {:type :block-quote
                         :children [{:type :paragraph :inlines [[:text "q"]]}]}]}]
    (is (= (str "<h2>T</h2>\n<hr />\n"
                "<pre><code class=\"language-x\">a&lt;b\n</code></pre>\n"
                "<pre><code class=\"language-clj\"></code></pre>\n"
                "<ol start=\"3\">\n<li>a</li>\n</ol>\n"
                "<ul>\n<li>\n<p>b</p>\n</li>\n<li></li>\n</ul>\n"
                "<blockquote>\n<p>q</p>\n</blockquote>\n")
           (html/render-document doc)))))
