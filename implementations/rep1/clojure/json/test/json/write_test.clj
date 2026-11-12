(ns json.write-test
  (:require [clojure.test :refer [deftest is testing]]
            [json.tree :as tree]
            [json.write :as write]))

(defn- obj [& kvs] (tree/obj-node (map vec (partition 2 kvs))))

(deftest scalars
  (is (= "null" (write/write-string nil)))
  (is (= "true" (write/write-string true)))
  (is (= "false" (write/write-string false)))
  (is (= "-0" (write/write-string (tree/num-node "-0"))))
  (is (= "[]" (write/write-string [])))
  (is (= "{}" (write/write-string (obj)))))

(deftest string-escaping
  (is (= "\"\\\"\\\\\\b\\f\\n\\r\\t\"" (write/write-string "\"\\\b\f\n\r\t")))
  (is (= "\"\\u0000\\u0001\\u001f\"" (write/write-string "\u0000\u0001\u001f")))
  (testing "everything else is raw"
    (is (= "\"/\u007f\u2028é😀\"" (write/write-string "/\u007f\u2028é😀")))))

(deftest object-ordering
  (testing "UTF-16 code unit order, not code point or UTF-8 order"
    (let [keys ["\uE000" "😀" "\uFFFF" "Z" "" "a" "a\u0000" "aa" "é"]
          out  (write/write-string (tree/obj-node (map #(vector % nil) keys)))]
      (is (= (str "{\"\":null,\"Z\":null,\"a\":null,\"a\\u0000\":null,\"aa\":null,"
                  "\"é\":null,\"😀\":null,\"\uE000\":null,\"\uFFFF\":null}")
             out))))
  (testing "duplicate keys keep the last value, at the key's sorted position"
    (is (= "{\"a\":3,\"b\":2}"
           (write/write-string
            (obj "b" (tree/num-node "2") "a" (tree/num-node "1") "a" (tree/num-node "3"))))))
  (testing "nested objects are sorted too"
    (is (= "[{\"a\":1,\"b\":{\"x\":1,\"y\":2}}]"
           (write/write-string
            [(obj "b" (obj "y" (tree/num-node "2") "x" (tree/num-node "1"))
                  "a" (tree/num-node "1"))])))))

(deftest bytes-output
  (is (= [0xF0 0x9F 0x98 0x80 0x22]
         (map #(bit-and % 0xFF) (rest (write/write-bytes "😀"))))))

(deftest rejects-non-tree-values
  (is (thrown? IllegalArgumentException (write/write-string :keyword)))
  (is (thrown? IllegalArgumentException (write/write-string 1))))
