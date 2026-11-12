(ns gitrepo.inflate-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [gitrepo.error :as err]
            [gitrepo.inflate :as inflate]
            [gitrepo.test-util :refer [bytes-of deflate]])
  (:import [java.util.zip Deflater]))

(defn- fails? [f]
  (try (f) false (catch Exception e (err/failure? e))))

(deftest levels-and-strategies
  (let [text (bytes-of (apply str (repeatedly 5000 #(rand-nth ["alpha " "beta " "gamma\n" "δ" "x"]))))]
    (doseq [level [0 1 6 9]
            strategy [Deflater/DEFAULT_STRATEGY Deflater/FILTERED Deflater/HUFFMAN_ONLY]]
      (is (= (seq text) (seq (:data (inflate/inflate (deflate text level strategy)))))
          (str "level " level " strategy " strategy)))))

(deftest empty-input
  (is (= 0 (alength ^bytes (:data (inflate/inflate (deflate (byte-array 0))))))))

(deftest reports-end-offset
  (let [a (deflate (bytes-of "first stream"))
        b (deflate (bytes-of "second"))
        both (byte-array (concat a b))
        r (inflate/inflate both 0)]
    (is (= (alength a) (:end r)))
    (is (= "second" (String. ^bytes (:data (inflate/inflate both (:end r))))))))

(deftest damaged-streams
  (let [good (deflate (bytes-of "hello hello hello hello"))]
    (testing "bad header"
      (is (fails? #(inflate/inflate (byte-array [0x78 0x00 0 0 0 0 0 0])))))
    (testing "preset dictionary"
      (is (fails? #(inflate/inflate (byte-array [0x78 0xbb 0 0 0 0 0 0])))))
    (testing "truncated"
      (is (fails? #(inflate/inflate (java.util.Arrays/copyOf ^bytes good 6)))))
    (testing "adler mismatch"
      (let [bad (aclone ^bytes good)]
        (aset bad (dec (alength bad)) (unchecked-byte (inc (aget bad (dec (alength bad))))))
        (is (fails? #(inflate/inflate bad)))))))

(defspec round-trip 300
  (prop/for-all [bs (gen/one-of [gen/bytes
                                 (gen/fmap #(byte-array (mapcat (fn [[n b]] (repeat n b)) %))
                                           (gen/vector (gen/tuple (gen/choose 1 400) gen/byte) 0 30))])
                 level (gen/elements [0 1 5 9])]
    (= (seq bs) (seq (:data (inflate/inflate (deflate bs level Deflater/DEFAULT_STRATEGY)))))))
