(ns gitrepo.sha1-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [gitrepo.sha1 :as sha1]
            [gitrepo.test-util :refer [bytes-of]])
  (:import [java.security MessageDigest]))

(deftest known-vectors
  (is (= "da39a3ee5e6b4b0d3255bfef95601890afd80709" (sha1/hex-digest (bytes-of ""))))
  (is (= "a9993e364706816aba3e25717850c26c9cd0d89d" (sha1/hex-digest (bytes-of "abc"))))
  (is (= "84983e441c3bd26ebaae4aa1f95129e5e54670f1"
         (sha1/hex-digest (bytes-of "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))))
  (testing "one million 'a'"
    (is (= "34aa973cd4c4daa4f61eeb2bdbad27316534016f"
           (sha1/hex-digest (bytes-of (apply str (repeat 1000000 \a))))))))

(deftest git-blob-id
  (is (= "b7814cae2e925fe74c6cd5816462fff515ccb256"
         (sha1/hex-digest (bytes-of "blob 9\u0000one file\n")))))

(defspec matches-the-jdk 200
  (prop/for-all [bs gen/bytes]
    (= (seq (sha1/digest bs))
       (seq (.digest (MessageDigest/getInstance "SHA-1") ^bytes bs)))))
