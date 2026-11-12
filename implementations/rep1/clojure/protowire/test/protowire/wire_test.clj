(ns protowire.wire-test
  (:require [clojure.test :refer [deftest is testing]]
            [protowire.hex :as hex]
            [protowire.test-util :refer [error?]]
            [protowire.wire :as wire]))

(defn- read-v [hex-str max-bytes]
  (let [b (hex/hex->bytes hex-str)]
    (wire/read-varint b (long-array 1) (alength b) max-bytes)))

(deftest varint-read
  (is (= 1 (read-v "01" 10)))
  (is (= 300 (read-v "ac02" 10)))
  (testing "non-minimal encodings are accepted"
    (is (= 1 (read-v "8100" 10))))
  (testing "values wrap modulo 2^64"
    (is (= -1 (read-v "ffffffffffffffffff7f" 10)))
    (is (= 0 (read-v "80808080808080808002" 10))))
  (testing "limits"
    (is (error? #(read-v "ffffffffffffffffffff01" 10)))
    (is (error? #(read-v "ff" 10)))
    (is (error? #(read-v "8080808080" 5)))))

(deftest varint-write
  (let [enc (fn [v]
              (let [out (byte-array 10)
                    n (wire/write-varint! out 0 v)]
                (hex/bytes->hex (java.util.Arrays/copyOf out (int n)))))]
    (is (= "00" (enc 0)))
    (is (= "01" (enc 1)))
    (is (= "ac02" (enc 300)))
    (is (= "ffffffffffffffffff01" (enc -1)))
    (is (= 10 (wire/varint-size -1)))
    (is (= 1 (wire/varint-size 127)))
    (is (= 2 (wire/varint-size 128)))))

(deftest tags-and-lengths
  (let [b (hex/hex->bytes "8080808010")] ; tag of 2^32
    (is (error? #(wire/read-tag b (long-array 1) (alength b)))))
  (let [b (hex/hex->bytes "05aabb")]
    (is (error? #(wire/read-length b (long-array 1) (alength b))))))

(deftest fixed-width
  (is (= (inc Long/MIN_VALUE)
         (wire/read-fixed64 (hex/hex->bytes "0100000000000080") (long-array 1) 8)))
  (is (= 4294967295
         (wire/read-fixed32 (hex/hex->bytes "ffffffff") (long-array 1) 4)))
  (is (error? #(wire/read-fixed32 (hex/hex->bytes "ffffff") (long-array 1) 3))))
