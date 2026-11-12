(ns kvstore.crc-test
  (:require [clojure.test :refer [deftest is testing]]
            [kvstore.bytes :as b]
            [kvstore.crc :as crc]))

(deftest spec-vectors
  (testing "test vectors from the specification, section 3"
    (is (= 0x00000000 (crc/crc32 (byte-array 0))))
    (is (= 0xE8B7BE43 (crc/crc32 (b/utf8 "a"))))
    (is (= 0xCBF43926 (crc/crc32 (b/utf8 "123456789"))))
    (is (= 0x2C9A9B66 (crc/crc32 (b/utf8 "TESSERA1"))))
    (is (= 0x7D446716 (crc/crc32 (b/utf8 "TESSWAL1"))))
    (is (= 0x0FD59B8D (crc/crc32 (byte-array 20))))
    (is (= 0xEFB5AF2E (crc/crc32 (byte-array 1024))))))

(deftest ranges-and-streaming
  (let [data (b/utf8 "xx123456789yy")]
    (is (= 0xCBF43926 (crc/crc32 data 2 9)))
    (is (= 0xCBF43926
           (crc/finish (-> crc/init
                           (crc/update-crc data 2 4)
                           (crc/update-crc data 6 5)))))))
