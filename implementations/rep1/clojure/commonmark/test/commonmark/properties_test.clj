(ns commonmark.properties-test
  "Property-based tests (test.check): the converter is total and deterministic
  on arbitrary input, and a few structural invariants hold."
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [commonmark.core :as cm]
            [commonmark.text :as t]))

(def ^:private fragments
  ["*" "**" "_" "__" "`" "``" "[" "]" "(" ")" "![" "<" ">" "<http://a.b>" "&amp;" "&#35;"
   "\\" "\n" "\n\n" "  " "\t" "> " "- " "1. " "# " "```" "~~~" "---" "***" "===" "    "
   "a" "b c" "\"t\"" "/url" "é"])

(def ^:private markdown-ish
  (gen/fmap str/join (gen/vector (gen/elements fragments) 0 60)))

(defspec never-throws 300
  (prop/for-all [md markdown-ish]
    (string? (cm/markdown->html md))))

(defspec deterministic 100
  (prop/for-all [md markdown-ish]
    (= (cm/markdown->html md) (cm/markdown->html md))))

(defspec output-is-newline-terminated 200
  (prop/for-all [md markdown-ish]
    (let [html (cm/markdown->html md)]
      (or (empty? html) (str/ends-with? html "\n")))))

(defspec html-is-balanced 200
  (prop/for-all [md markdown-ish]
    (let [html (cm/markdown->html md)
          count-of (fn [re] (count (re-seq re html)))]
      (and (= (count-of #"<em>") (count-of #"</em>"))
           (= (count-of #"<strong>") (count-of #"</strong>"))
           (= (count-of #"<blockquote>") (count-of #"</blockquote>"))
           (= (count-of #"<li>") (count-of #"</li>"))
           (= (count-of #"<p>") (count-of #"</p>"))
           (= (count-of #"<pre><code") (count-of #"</code></pre>"))))))

(defspec no-raw-angle-brackets-from-text 200
  ;; Text made of letters, spaces and the HTML-special characters never
  ;; produces markup other than the paragraph itself.
  (prop/for-all [s (gen/fmap str/join (gen/vector (gen/elements ["a" "b" " " "<" ">" "&" "\""]) 1 30))]
    (let [html (cm/markdown->html (str "x" s "x"))
          body (second (re-matches #"(?s)<p>(.*)</p>\n" html))]
      (and body (not (re-find #"[<>\"]" body))))))

(defspec plain-words-form-one-paragraph 200
  (prop/for-all [words (gen/vector (gen/fmap str/join (gen/vector gen/char-alpha 1 8)) 1 12)]
    (= (str "<p>" (str/join " " words) "</p>\n")
       (cm/markdown->html (str/join " " words)))))

(defspec escape-html-leaves-no-specials 200
  (prop/for-all [s gen/string]
    (not (re-find #"[<>\"]|&(?!amp;|lt;|gt;|quot;)" (t/escape-html s)))))

(defspec code-spans-round-trip 200
  ;; The content of a code span comes out escaped but otherwise unchanged.
  (prop/for-all [s (gen/fmap str/join (gen/vector (gen/elements ["a" "b" "<" "&" "*" "_" "[" "x"]) 1 20))]
    (= (str "<p><code>" (t/escape-html s) "</code></p>\n")
       (cm/markdown->html (str "`" s "`")))))
