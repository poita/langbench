(ns textbuffer.document-test
  (:require [clojure.test :refer [deftest is testing]]
            [textbuffer.document :as doc]
            [textbuffer.position :as p]))

(defn- edit [d from to text]
  (-> (doc/thaw d) (doc/replace! (apply p/pos from) (apply p/pos to) text) doc/freeze))

(deftest construction
  (is (= [""] (doc/lines (doc/document []))))
  (is (= ["a" "" "b"] (doc/lines (doc/from-text "a\n\nb"))))
  (is (= [""] (doc/lines (doc/from-text ""))))
  (is (= "a\nb" (doc/text (doc/document ["a" "b"])))))

(deftest queries
  (let [d (doc/document ["abc" "" "de"])]
    (is (= 3 (doc/line-count d)))
    (is (= 3 (doc/line-length d 0)))
    (is (= "de" (doc/line-text d 2)))
    (is (= [2 2] (p/->vec (doc/end-position d))))))

(deftest clamping
  (let [d (doc/document ["abc" "" "de"])]
    (is (= [0 3] (p/->vec (doc/clamp d 0 1000000000))))
    (is (= [2 1] (p/->vec (doc/clamp d 1000000000 1))))
    (is (= [2 2] (p/->vec (doc/clamp d 9 9))))
    (is (= [1 0] (p/->vec (doc/clamp d 1 5))))))

(deftest slicing
  (let [d (doc/document ["abc" "" "de"])]
    (is (= "b" (doc/slice d (p/pos 0 1) (p/pos 0 2))))
    (is (= "" (doc/slice d (p/pos 1 0) (p/pos 1 0))))
    (is (= "c\n\nd" (doc/slice d (p/pos 0 2) (p/pos 2 1))))
    (is (= "abc\n\nde" (doc/slice d p/origin (doc/end-position d))))
    (is (= "\n" (doc/slice d (p/pos 0 3) (p/pos 1 0))))))

(deftest replacing
  (let [d (doc/document ["abc" "def" "ghi"])]
    (testing "within a line"
      (is (= ["aXXc" "def" "ghi"] (doc/lines (edit d [0 1] [0 2] "XX")))))
    (testing "pure insertion and deletion"
      (is (= ["abZc" "def" "ghi"] (doc/lines (edit d [0 2] [0 2] "Z"))))
      (is (= ["ac" "def" "ghi"] (doc/lines (edit d [0 1] [0 2] "")))))
    (testing "joining lines"
      (is (= ["abcdef" "ghi"] (doc/lines (edit d [0 3] [1 0] ""))))
      (is (= ["ai"] (doc/lines (edit d [0 1] [2 2] "")))))
    (testing "inserting newlines"
      (is (= ["a" "" "bc" "def" "ghi"] (doc/lines (edit d [0 1] [0 1] "\n\n"))))
      (is (= ["aX" "Yef" "ghi"] (doc/lines (edit d [0 1] [1 1] "X\nY")))))
    (testing "multi-line replaced by multi-line"
      (is (= ["a1" "2" "3i"] (doc/lines (edit d [0 1] [2 2] "1\n2\n3")))))
    (testing "the original document is untouched"
      (edit d [0 0] [2 3] "")
      (is (= ["abc" "def" "ghi"] (doc/lines d))))))

(deftest editing-requires-thaw
  (let [d (doc/document ["abc"])]
    (is (thrown? IllegalStateException (doc/replace! d p/origin p/origin "x")))
    (let [t (doc/thaw d)]
      (doc/freeze t)
      (is (thrown? IllegalStateException (doc/replace! t p/origin p/origin "x"))))))
