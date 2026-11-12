(ns mime.header-test
  (:require [clojure.test :refer [deftest is]]
            [mime.header :as h]))

(defn- parse [s] (h/parse-block (.getBytes ^String s "UTF-8")))

(deftest block-ends
  (let [{:keys [fields body-start]} (parse "A: 1\n  cont\nB:2\n\nbody")]
    (is (= [["A" " 1  cont"] ["B" "2"]] (mapv (juxt :name :raw) fields)))
    (is (= 17 body-start)))
  (is (= [] (:fields (parse "no colon here\nA: b"))))
  (is (= 0 (:body-start (parse "Subject :x\n"))))
  (is (= 1 (count (:fields (parse "A: b\nSubject :x\nrest")))))
  (is (= [] (:fields (parse " leading: space\n")))))

(deftest display-values
  (is (= "a b" (h/display-value {:key "content-type" :raw "  a \t b "})))
  (is (= "café" (h/display-value {:key "subject" :raw " =?utf-8?Q?caf=C3=A9?= "}))))

(deftest lookup
  (let [{:keys [fields]} (parse "X: 1\nx: 2\n\n")]
    (is (= " 1" (:raw (h/find-field fields "x"))))))
