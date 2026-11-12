(ns json.utf8-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [json.utf8 :as utf8])
  (:import (java.nio ByteBuffer)
           (java.nio.charset CodingErrorAction StandardCharsets)))

(defn- bytes-of [& xs]
  (byte-array (map unchecked-byte xs)))

(defn- jdk-valid?
  "Reference oracle: the JDK's strict decoder."
  [^bytes bs]
  (try
    (-> (.newDecoder StandardCharsets/UTF_8)
        (.onMalformedInput CodingErrorAction/REPORT)
        (.onUnmappableCharacter CodingErrorAction/REPORT)
        (.decode (ByteBuffer/wrap bs)))
    true
    (catch java.nio.charset.CharacterCodingException _ false)))

(deftest valid-sequences
  (is (utf8/valid? (byte-array 0)))
  (is (utf8/valid? (.getBytes "plain ascii" StandardCharsets/UTF_8)))
  (is (utf8/valid? (bytes-of 0xC2 0x80)))
  (is (utf8/valid? (bytes-of 0xDF 0xBF)))
  (is (utf8/valid? (bytes-of 0xE0 0xA0 0x80)))
  (is (utf8/valid? (bytes-of 0xED 0x9F 0xBF)))
  (is (utf8/valid? (bytes-of 0xEE 0x80 0x80)))
  (is (utf8/valid? (bytes-of 0xF0 0x90 0x80 0x80)))
  (is (utf8/valid? (bytes-of 0xF4 0x8F 0xBF 0xBF))))

(deftest invalid-sequences
  (testing "stray continuation and bad lead bytes"
    (doseq [b [0x80 0xBF 0xC0 0xC1 0xF5 0xFF]]
      (is (not (utf8/valid? (bytes-of b 0x80 0x80 0x80))) (format "%02X" b))))
  (testing "overlong"
    (is (not (utf8/valid? (bytes-of 0xC0 0xAF))))
    (is (not (utf8/valid? (bytes-of 0xE0 0x80 0xAF))))
    (is (not (utf8/valid? (bytes-of 0xF0 0x80 0x80 0xAF)))))
  (testing "surrogates"
    (is (not (utf8/valid? (bytes-of 0xED 0xA0 0x80))))
    (is (not (utf8/valid? (bytes-of 0xED 0xBF 0xBF)))))
  (testing "above U+10FFFF"
    (is (not (utf8/valid? (bytes-of 0xF4 0x90 0x80 0x80)))))
  (testing "truncated"
    (is (not (utf8/valid? (bytes-of 0xC2))))
    (is (not (utf8/valid? (bytes-of 0xE2 0x82))))
    (is (not (utf8/valid? (bytes-of 0xF0 0x9F 0x98))))
    (is (not (utf8/valid? (bytes-of 0x41 0xF0 0x9F 0x98 0x41))))))

(defspec agrees-with-jdk-decoder 2000
  (prop/for-all [bs (gen/fmap #(byte-array (map unchecked-byte %))
                              (gen/vector (gen/frequency
                                           [[3 (gen/elements [0x41 0x80 0xBF 0xC2 0xE0 0xED
                                                              0xF0 0xF4 0xA0 0x9F 0x90 0x8F 0xFF])]
                                            [1 (gen/choose 0 255)]])
                                          0 8))]
    (= (utf8/valid? bs) (jdk-valid? bs))))
