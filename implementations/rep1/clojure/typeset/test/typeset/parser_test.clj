(ns typeset.parser-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [typeset.parser :as p]
            [typeset.util :as u]))

(defn- err [& lines]
  (try (p/parse (str (str/join "\n" lines) "\n")) nil
       (catch clojure.lang.ExceptionInfo e (u/error-line (u/input-error e)))))

(defn- doc [& lines] (p/parse (str (str/join "\n" lines) "\n")))

(deftest block-structure
  (let [d (doc "@doc" "title = T" "@end" "@toc" "@h1 Intro" "Hello" "world." ""
               "@ul" "@li one" "  more" "@li two" "@end")]
    (is (= "T" (get-in d [:meta "title"])))
    (is (= {:title nil} (:toc d)))
    (is (= [:heading :paragraph :ul] (map :type (:blocks d))))
    (is (= 2 (count (:items (nth (:blocks d) 2)))))))

(deftest nesting-and-items
  (let [d (doc "@ul" "@li a" "@q" "text" "@end" "@li b" "@end")
        items (:items (first (:blocks d)))]
    (is (= [:q] (map :type (:children (first items)))))
    (is (= [] (:children (second items))))))

(deftest tables
  (let [d (doc "@table cols=2 align=lr" "a | b" "@hrule" "c|d" "@end")
        t (first (:blocks d))]
    (is (= 2 (:cols t)))
    (is (= [\l \r] (:aligns t)))
    (is (= [:row :hrule :row] (map #(if (map? %) :row %) (:elements t))))))

(deftest error-codes-and-positions
  (is (= "document.cdx:1:1: unknown-block" (err "@h1x A")))
  (is (= "document.cdx:2:1: unexpected-end" (err "ab" "@end")) "the paragraph is fine, the end is not")
  (is (= "document.cdx:3:1: missing-end" (err "@q" "x")))
  (is (= "document.cdx:1:8: bad-attribute" (err "@table foo=1")))
  (is (= "document.cdx:1:1: missing-attribute" (err "@table align=xyz")))
  (is (= "document.cdx:1:1: block-not-allowed" (err "@li x")))
  (is (= "document.cdx:2:1: block-not-allowed" (err "text" "@doc")))
  (is (= "document.cdx:2:1: duplicate-toc" (err "@toc" "@toc")))
  (is (= "document.cdx:1:1: unknown-block" (err "@nope")))
  (is (= "document.cdx:3:1: cell-count" (err "@table cols=2" "a|b" "a|b|c" "@end")))
  (is (= "document.cdx:2:1: text-not-allowed" (err "@ul" "text" "@end")))
  (is (= "document.cdx:2:1: block-not-allowed" (err "@ul" "@q" "@end")))
  (is (= "document.cdx:2:1: bad-syntax" (err "@doc" "nonsense" "@end")))
  (is (= "document.cdx:2:1: unknown-meta" (err "@doc" "mood = good" "@end")))
  (is (= "document.cdx:3:1: duplicate-meta" (err "@doc" "title = a" "title = b" "@end"))))

(deftest attribute-lexing
  (is (= "document.cdx:1:16: bad-attribute-value" (err "@vspace height=")))
  (is (= "document.cdx:1:16: bad-attribute-value" (err "@vspace height=\"10pt\"x")))
  (is (= "document.cdx:1:16: bad-attribute-value" (err "@vspace height=abc")))
  (is (= "document.cdx:2:1: block-not-allowed" (err "@table cols=1" "@vspace height=abc" "@end")) "placement before value")
  (is (= "document.cdx:1:1: unexpected-end" (err "@end")))
  (is (= "document.cdx:1:6: bad-attribute" (err "@end foo=1"))))

(deftest second-toc-placement
  (is (= "document.cdx:3:1: duplicate-toc" (err "@toc" "@q" "@toc")))
  (is (= "document.cdx:3:1: block-not-allowed" (err "@toc" "@table cols=1" "@toc"))))

(deftest pre-blocks-are-raw
  (let [d (doc "@pre" "  x  " "@h1 not a heading" "" "@end")]
    (is (= ["  x" "@h1 not a heading" ""] (:lines (first (:blocks d)))))))
