(ns webhooks.primitives-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [webhooks.base64 :as b64]
            [webhooks.bytes :as bytes]
            [webhooks.hex :as hex]
            [webhooks.hmac :as hmac]
            [webhooks.sha256 :as sha256]))

(defn- sha-hex [^String s] (hex/encode (sha256/digest (bytes/utf8 s))))

(deftest sha256-vectors
  (is (= "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" (sha-hex "")))
  (is (= "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" (sha-hex "abc")))
  (testing "padding boundaries"
    (is (= "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
           (sha-hex "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")))
    (is (= "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
           (sha-hex (apply str (repeat 1000000 \a)))))
    (is (= 32 (alength (sha256/digest (byte-array 55)))))
    (is (not= (sha-hex (apply str (repeat 55 \a))) (sha-hex (apply str (repeat 56 \a)))))))

(deftest hmac-vectors
  (is (= "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
         (hex/encode (hmac/hmac-sha256 (byte-array 20 (byte 0x0b)) (bytes/utf8 "Hi There")))))
  (is (= "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad"
         (hex/encode (hmac/hmac-sha256 (byte-array 0) (byte-array 0)))))
  (testing "RFC 4231 case 6: key longer than the block"
    (is (= "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
           (hex/encode (hmac/hmac-sha256
                        (byte-array 131 (byte -86))
                        (bytes/utf8 "Test Using Larger Than Block-Size Key - Hash Key First")))))))

(deftest base64-encoding
  (is (= ["" "Zg==" "Zm8=" "Zm9v" "+/8="]
         (mapv #(b64/encode (bytes/ascii %)) ["" "f" "fo" "foo" "ûÿ"])))
  (is (= ["" "Zg" "Zm8" "Zm9v" "-_8"]
         (mapv #(b64/encode-url (bytes/ascii %)) ["" "f" "fo" "foo" "ûÿ"]))))

(defn- dec-hex [s] (some-> (b64/decode s) hex/encode))

(deftest base64-decoding
  (testing "valid"
    (is (= "" (dec-hex "")))
    (is (= "666f6f" (dec-hex "Zm9v")))
    (is (= "fbff" (dec-hex "-_8")))
    (is (= "fbff" (dec-hex "+/8=")))
    (is (= "fbff" (dec-hex "+/8")))
    (testing "left-over bits are ignored"
      (is (= "41" (dec-hex "QQ==")))
      (is (= "41" (dec-hex "QR==")))))
  (testing "invalid"
    (doseq [s ["Q" "QQ=" "QQQ==" "Zm9v=" "====" "Zm=9" "+-8=" "Zm 9" "Zm9v\n" "Zm9é"
               "QQ===" "=Zm9"]]
      (is (nil? (b64/decode s)) (pr-str s)))))

(defspec base64-round-trip 200
  (prop/for-all [bs (gen/fmap byte-array (gen/vector (gen/choose -128 127) 0 100))]
    (and (= (seq bs) (seq (b64/decode (b64/encode bs))))
         (= (seq bs) (seq (b64/decode (b64/encode-url bs)))))))

(defspec hex-round-trip 200
  (prop/for-all [bs (gen/fmap byte-array (gen/vector (gen/choose -128 127) 0 100))]
    (= (seq bs) (seq (hex/decode (hex/encode bs))))))

(deftest hex-strictness
  (is (nil? (hex/decode "AB")))
  (is (nil? (hex/decode "abc")))
  (is (nil? (hex/decode "zz")))
  (is (= 0 (alength ^bytes (hex/decode "")))))
