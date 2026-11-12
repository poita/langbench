(ns mime.transfer-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [mime.transfer :as t]))

(defn- qp [s] (String. (t/decode-quoted-printable (.getBytes ^String s "ISO-8859-1")) "ISO-8859-1"))

(deftest quoted-printable-examples
  (is (= "a b" (qp "a=20b")))
  (is (= "ab" (qp "a=\nb")))
  (is (= "a=b" (qp "a=3Db")))
  (is (= "a=Zb" (qp "a=Zb")))
  (is (= "a=3\n" (qp "a=3\n")))
  (is (= "abc" (qp "abc=")))
  (is (= "\r\n" (qp "=0D=0A")))
  (is (= "x  \ny" (qp "x  \ny"))))

(deftest base64-examples
  (is (= [0 1 2 3] (map #(bit-and % 0xff) (t/decode-base64 (.getBytes "AAECAw==")))))
  (is (= "Jörg" (String. (t/decode-base64 (.getBytes "SsO2cmc=")) "UTF-8")))
  (is (= "a" (String. (t/decode-base64-string "YQ") "UTF-8")) "unpadded 2-char tail")
  (is (= "ab" (String. (t/decode-base64-string "YW I") "UTF-8")) "junk is skipped")
  (is (= 3 (alength (t/decode-base64-string "AAAAA"))) "a lone final character is dropped"))

(deftest decode-body-dispatch
  (let [b (.getBytes "a=20")]
    (is (identical? b (t/decode-body b "7bit")))
    (is (identical? b (t/decode-body b "x-weird")))
    (is (= "a " (String. (t/decode-body b "quoted-printable"))))))

(defspec base64-round-trip 200
  (prop/for-all [v (gen/vector gen/byte 0 100)]
    (let [b (byte-array v)
          enc (.encodeToString (java.util.Base64/getMimeEncoder) b)]
      (java.util.Arrays/equals b (t/decode-base64 (.getBytes enc "US-ASCII"))))))
