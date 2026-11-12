(ns commonmark.blocks-test
  (:require [clojure.test :refer [deftest is testing]]
            [commonmark.blocks :as blocks]))

(defn- types [node] (mapv :type (:children node)))
(defn- blocks-of [md] (:children (blocks/parse-blocks md)))
(defn- block [md] (first (blocks-of md)))

(deftest empty-and-trivial
  (is (= {:type :document :children []} (blocks/parse-blocks "")))
  (is (= [] (blocks-of "\n\n  \n")))
  (is (= [{:type :paragraph :content "a\n"}] (blocks-of "a")))
  (is (= [{:type :paragraph :content "a\n"}] (blocks-of "a\n"))))

(deftest headings
  (is (= {:type :heading :level 1 :content "foo\n"} (block "# foo #")))
  (is (= {:type :heading :level 3 :content "\n"} (block "### ###")))
  (is (= {:type :heading :level 2 :content "foo#\n"} (block "## foo#")))
  (is (= :paragraph (:type (block "####### x"))))
  (is (= :paragraph (:type (block "#hashtag"))))
  (testing "setext headings"
    (is (= {:type :heading :level 1 :content "a\nb\n"} (block "a\nb\n===")))
    (is (= {:type :heading :level 2 :content "a\n"} (block "a\n---")))
    (is (= [:block-quote :thematic-break] (types (blocks/parse-blocks "> a\n---"))))))

(deftest thematic-breaks
  (is (= [:thematic-break] (types (blocks/parse-blocks "* * *"))))
  (is (= [:thematic-break] (types (blocks/parse-blocks "_ __ _"))))
  (is (= [:list] (types (blocks/parse-blocks "- - x"))))
  (is (= [:paragraph] (types (blocks/parse-blocks "--")))))

(deftest code-blocks
  (is (= {:type :code-block :info "" :literal "a\n\nb\n"} (block "    a\n\n    b\n\n")))
  (is (= {:type :code-block :info "" :literal "a  \n"} (block "    a  ")))
  (is (= {:type :code-block :info "clj" :literal "x\n  y\n"} (block "```clj\nx\n  y\n```")))
  (is (= {:type :code-block :info "a&b" :literal ""} (block "~~~ a&amp;b")))
  (is (= {:type :code-block :info "*" :literal "x\n"} (block "``` \\*\nx")) "unclosed fence runs to the end")
  (testing "indentation of the fence is removed from the content"
    (is (= "a\n b\n" (:literal (block "  ```\n  a\n   b\n  ```")))))
  (testing "a closing fence must be at least as long"
    (is (= "a\n````\n" (:literal (block "`````\na\n````\n`````")))))
  (testing "tabs"
    (is (= "  bar\n" (:literal (second (:children (first (:children (block "- foo\n\n\t\tbar")))))))))
  (is (= :paragraph (:type (block "para\n    not code")))))

(deftest block-quotes
  (is (= [:block-quote] (types (blocks/parse-blocks ">a\n> b"))))
  (is (= "a\nb\n" (:content (first (:children (block "> a\nb"))))) "lazy continuation")
  (is (= [:block-quote :block-quote] (types (blocks/parse-blocks "> a\n\n> b"))))
  (is (= [:block-quote :paragraph] (types (blocks/parse-blocks "> a\n    b\n\nc")))))

(deftest lists
  (let [l (block "1. a\n2. b")]
    (is (= :list (:type l)))
    (is (true? (:ordered? l)))
    (is (= 1 (:start l)))
    (is (true? (:tight? l))))
  (is (= 3 (:start (block "003. a"))))
  (is (= [:list :list] (types (blocks/parse-blocks "- a\n+ b"))) "a different bullet starts a new list")
  (is (= [:list :list] (types (blocks/parse-blocks "1. a\n1) b"))))
  (is (= [:paragraph] (types (blocks/parse-blocks "a\n2. b"))) "only 1. interrupts a paragraph")
  (is (= [:paragraph :list] (types (blocks/parse-blocks "a\n1. b"))))
  (is (= [:paragraph] (types (blocks/parse-blocks "a\n*\nb"))) "an empty item cannot interrupt a paragraph")
  (testing "tight and loose"
    (is (true? (:tight? (block "- a\n- b\n  - c"))))
    (is (false? (:tight? (block "- a\n\n- b"))))
    (is (false? (:tight? (block "- a\n\n  b"))))
    (is (true? (:tight? (block "- a\n  ```\n\n  ```\n- b"))) "blank lines in code fences do not count")
    (is (true? (:tight? (block "- a\n  > b\n  >\n  > c\n- d"))) "blank lines inside a block quote do not count")
    (is (false? (:tight? (block "- a\n  > b\n\n  > c")))))
  (testing "empty items"
    (is (= [{:type :list-item :children []}] (:children (block "-"))))
    (is (= 2 (count (:children (block "-\n- a"))))))
  (testing "nesting by indentation"
    (let [outer (block "- a\n  - b\n    - c")]
      (is (= [:paragraph :list] (types (first (:children outer))))))))

(deftest deep-nesting
  (let [depth 300
        doc (blocks/parse-blocks (str (apply str (repeat depth "> ")) "x"))]
    (is (= depth (count (take-while #(= :block-quote (:type %))
                                    (iterate #(first (:children %)) (first (:children doc)))))))))
