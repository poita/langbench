(ns mime.part-test
  (:require [clojure.test :refer [deftest is]]
            [mime.part :as p]))

(defn- b ^bytes [^String s] (.getBytes s "UTF-8"))
(defn- str-of [^bytes x] (String. x "UTF-8"))

(deftest multipart-splitting
  (let [r (p/split-multipart (b "pre\n--X\nA\n--X\n\n--X--\ntail\n") (b "X"))]
    (is (= 3 (:preamble r)))
    (is (= ["A" ""] (mapv str-of (:children r))))
    (is (= 5 (:epilogue r))))
  (is (= {:preamble 4 :epilogue nil :children []} (p/split-multipart (b "none") (b "X"))))
  (is (= ["a" "b"] (mapv str-of (:children (p/split-multipart (b "--X \t\na\n--X\nb") (b "X"))))))
  (is (= [""] (mapv str-of (:children (p/split-multipart (b "--X\n--X--") (b "X")))))
      "adjacent delimiters bound an empty part"))

(deftest default-types
  (let [digest (p/parse-part (b "Content-Type: multipart/digest; boundary=d\n\n--d\n\nSubject: x\n\nhi\n--d--\n") nil)
        child (first (:children digest))]
    (is (= :message (:kind child)))
    (is (= "text" (:type (first (:children child)))))))

(deftest numbering
  (let [root (p/parse-part (b "Content-Type: multipart/mixed; boundary=\"b\"\n\n--b\n\none\n--b\nContent-Type: multipart/mixed; boundary=c\n\n--c\n\ntwo\n--c--\n--b--\n") nil)
        flat (p/flatten-parts root)]
    (is (= [0 1 2 3] (map :index flat)))
    (is (= [0 1 1 2] (map :depth flat)))
    (is (= [2 0 1 0] (map :child-count flat)))))
