(ns svgraster.xml-test
  (:require [clojure.test :refer [deftest is testing]]
            [svgraster.xml :as xml]))

(deftest basic-tree
  (let [root (xml/parse "<svg a='1' b=\"2\"><g><rect x = '3'/></g><path d='M0 0'/></svg>")]
    (is (= "svg" (:tag root)))
    (is (= {"a" "1" "b" "2"} (:attrs root)))
    (is (= ["g" "path"] (map :tag (:children root))))
    (is (= {"x" "3"} (:attrs (first (:children (first (:children root)))))))))

(deftest skipped-constructs
  (let [root (xml/parse "<?xml version='1.0'?>
<!-- <svg> not this -->
<!DOCTYPE svg [ <!ENTITY e 'a>b'> ]>
<svg><![CDATA[ <rect/> ]]>text<g/></svg>")]
    (is (= "svg" (:tag root)))
    (is (= ["g"] (map :tag (:children root))))))

(deftest namespaces-are-stripped
  (let [root (xml/parse "<svg:svg xmlns:svg='u' xmlns:xlink='v'><svg:use xlink:href='#a'/></svg:svg>")]
    (is (= "svg" (:tag root)))
    (is (= "use" (:tag (first (:children root)))))
    (is (= "#a" (get-in root [:children 0 :attrs "href"])))))

(deftest attribute-values
  (testing "`>` inside quotes does not end the tag"
    (is (= "a>b" (get-in (xml/parse "<svg d='a>b'/>") [:attrs "d"]))))
  (testing "entities"
    (is (= "<&>\"' A B &foo;"
           (get-in (xml/parse "<svg d='&lt;&amp;&gt;&quot;&apos; &#65; &#x42; &foo;'/>")
                   [:attrs "d"]))))
  (testing "the last duplicate wins"
    (is (= "2" (get-in (xml/parse "<svg a='1' a='2'/>") [:attrs "a"])))))

(deftest entity-decoding
  (is (= "plain" (xml/decode-entities "plain")))
  (is (= "a&b" (xml/decode-entities "a&amp;b")))
  (is (= "&" (xml/decode-entities "&")))
  (is (= "&#xZZ;" (xml/decode-entities "&#xZZ;"))))

(deftest no-document-element
  (is (thrown? clojure.lang.ExceptionInfo (xml/parse "just text")))
  (is (thrown? clojure.lang.ExceptionInfo (xml/parse "<!-- nothing -->"))))
