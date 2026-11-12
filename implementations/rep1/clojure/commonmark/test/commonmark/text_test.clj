(ns commonmark.text-test
  (:require [clojure.test :refer [deftest is testing]]
            [commonmark.text :as t]))

(deftest character-classes
  (is (every? t/ws? [32 9 10 11 12 13]))
  (is (not-any? t/ws? [0 8 14 31 33 65 160]))
  (is (every? t/ascii-punct? (map int "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")))
  (is (not-any? t/ascii-punct? (map int "aZ09 \t")))
  (is (== -1 (t/char-at "abc" 3)))
  (is (== 98 (t/char-at "abc" 1))))

(deftest trimming
  (is (= "a b" (t/trim-ws " \t a b \n")))
  (is (= " a" (t/rtrim-ws " a \n\n")))
  (is (= "" (t/trim-ws " \n "))))

(deftest entities
  (testing "named entities are limited to the four of the spec"
    (is (= "&<>\"" (t/decode-entities "&amp;&lt;&gt;&quot;")))
    (is (= "&copy; &AMP; &amp" (t/decode-entities "&copy; &AMP; &amp"))))
  (testing "numeric references"
    (is (= "AB" (t/decode-entities "&#65;&#x42;")))
    (is (= "\uFFFD" (t/decode-entities "&#0;")))
    (is (= "\uFFFD" (t/decode-entities "&#xD800;")))
    (is (= "\uFFFD" (t/decode-entities "&#x110000;")))
    (is (= "\uD83D\uDE00" (t/decode-entities "&#x1F600;")))
    (is (= "&#12345678;" (t/decode-entities "&#12345678;")) "8 digits is too many")
    (is (= "&#;&#x;" (t/decode-entities "&#;&#x;")))))

(deftest backslash-escapes
  (is (= "*a* \\b" (t/unescape-backslashes "\\*a\\* \\b")))
  (testing "entities are decoded before backslashes are removed"
    (is (= "&" (t/clean-string "\\&amp;")))
    (is (= "*" (t/clean-string "&#92;*")))))

(deftest html-escaping
  (is (= "&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt; 'é'" (t/escape-html "<a href=\"x\">&</a> 'é'")))
  (is (= "plain" (t/escape-html "plain"))))

(defn- href [url]
  (str (t/encode-url! (StringBuilder.) url)))

(deftest url-encoding
  (is (= "/my%20uri" (href "/my uri")))
  (is (= "http://a.b/?x=1&amp;y=2" (href "http://a.b/?x=1&y=2")))
  (is (= "%C3%A4%20%E2%82%AC" (href "ä €")))
  (is (= "a%b%20c%22d" (href "a%b c\"d")) "percent signs are copied, quotes encoded")
  (is (= "it&#x27;s" (href "it's")))
  (is (= "" (href "javascript:alert(1)")))
  (is (= "" (href "JaVaScRiPt:x")))
  (is (= "" (href "data:text/html,x")))
  (is (= "data:image/png;base64,AAAA" (href "data:image/png;base64,AAAA")))
  (is (= "/a%5Bb%5D%5C" (href "/a[b]\\"))))
