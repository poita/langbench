(ns commonmark.inlines-test
  (:require [clojure.test :refer [deftest is testing]]
            [commonmark.inlines :as inlines]))

(defn- ev [s] (inlines/parse-inlines s))

(defn- ev-merged
  "Like `ev`, with adjacent text events joined."
  [s]
  (reduce (fn [acc e]
            (if (and (= :text (first e)) (= :text (first (peek acc))))
              (conj (pop acc) [:text (str (second (peek acc)) (second e))])
              (conj acc e)))
          [] (ev s)))

(deftest plain-text
  (is (= [] (ev "")))
  (is (= [[:text "hello world"]] (ev "hello world")))
  (is (= [[:text "a"] [:softbreak] [:text "b"]] (ev "a\nb")))
  (is (= [[:text "a"] [:linebreak] [:text "b"]] (ev "a  \nb")))
  (is (= [[:text "a"] [:linebreak] [:text "b"]] (ev "a\\\nb")))
  (is (= [[:text "a"]] (ev "a   \n")) "trailing whitespace is dropped"))

(deftest escapes-and-entities
  (is (= "*" (second (first (ev "\\*")))))
  (is (= [[:text "\\"] [:text "a"]] (ev "\\a")))
  (is (= [[:text "&"]] (ev "&amp;")))
  (is (= [[:text "&"] [:text "copy;"]] (ev "&copy;")))
  (is (= [[:text "A"]] (ev "&#65;"))))

(deftest code-spans
  (is (= [[:code "a"]] (ev "`a`")))
  (is (= [[:code "a b"]] (ev "`a\nb`")))
  (is (= [[:code "a"]] (ev "`` a ``")) "one space is stripped on each side")
  (is (= [[:code " "]] (ev "` `")))
  (is (= [[:code "a`b"]] (ev "``a`b``")))
  (is (= [[:text "`"] [:text "a"]] (ev "`a")))
  (is (= [[:text "``"] [:text "a"] [:text "`"] [:text " b"]] (ev "``a` b"))
      "runs of different lengths do not match"))

(deftest emphasis
  (is (= [[:start :emph] [:text "a"] [:end :emph]] (ev "*a*")))
  (is (= [[:start :strong] [:text "a"] [:end :strong]] (ev "**a**")))
  (is (= [[:start :emph] [:start :strong] [:text "a"] [:end :strong] [:end :emph]] (ev "***a***")))
  (is (= [[:text "a_b_c"]] (ev-merged "a_b_c")) "intraword underscores")
  (is (= [[:text "* a *"]] (ev-merged "* a *")))
  (testing "the rule of 3"
    (is (= [[:start :emph] [:text "foo"] [:start :strong] [:text "bar"] [:end :strong] [:text "baz"] [:end :emph]]
           (ev "*foo**bar**baz*")))))

(deftest links-and-images
  (is (= [[:start :link {:destination "/u" :title nil}] [:text "a"] [:end :link]] (ev "[a](/u)")))
  (is (= [[:start :link {:destination "/u" :title "t"}] [:text "a"] [:end :link]] (ev "[a](/u \"t\")")))
  (is (= [[:start :image {:destination "/i" :title nil}] [:text "a"] [:end :image]] (ev "![a](/i)")))
  (is (= [[:text "["] [:text "a"] [:text "]"]] (ev "[a]")) "no reference links")
  (is (= [[:text "!"] [:text "a"]] (ev "!a")))
  (testing "links do not contain links"
    (let [events (ev "[a [b](/u) c](/v)")]
      (is (= 1 (count (filter #{[:start :link {:destination "/u" :title nil}]} events))))
      (is (= 0 (count (filter #(= [:start :link {:destination "/v" :title nil}] %) events))))))
  (testing "emphasis inside link text"
    (is (= [[:start :link {:destination "/u" :title nil}]
            [:start :emph] [:text "a"] [:end :emph]
            [:end :link]]
           (ev "[*a*](/u)"))))
  (testing "emphasis does not cross a link boundary"
    (is (not-any? #{[:start :emph]} (ev "*[a*](/u)")))))

(deftest autolinks
  (is (= [[:start :link {:destination "http://a.b/?x=1&y=2" :title nil}]
          [:text "http://a.b/?x=1&y=2"]
          [:end :link]]
         (ev "<http://a.b/?x=1&amp;y=2>")))
  (is (= [[:start :link {:destination "mailto:a@b.c" :title nil}] [:text "a@b.c"] [:end :link]]
         (ev "<a@b.c>")))
  (is (= [[:text "<"] [:text "a b>"]] (ev "<a b>"))))

(deftest deep-nesting-does-not-overflow
  (let [n 20000
        events (ev (str (apply str (repeat n "*a ")) "b" (apply str (repeat n " c*"))))]
    (is (pos? (count events))))
  (let [n 10000
        events (ev (str (apply str (repeat n "[")) "a" (apply str (repeat n "](/u)"))))]
    (is (pos? (count events)))))
